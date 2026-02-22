package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/open-dingtalk/dingtalk-stream-sdk-go/chatbot"
	"github.com/open-dingtalk/dingtalk-stream-sdk-go/client"
	"github.com/open-dingtalk/dingtalk-stream-sdk-go/event"
	"github.com/open-dingtalk/dingtalk-stream-sdk-go/logger"
	"github.com/open-dingtalk/dingtalk-stream-sdk-go/payload"
)

const (
	defaultIngressURL = "http://127.0.0.1:4010/internal/dingtalk/stream"
	defaultTopic      = "/v1.0/im/bot/messages/get"
)

type config struct {
	AppKey        string
	AppSecret     string
	IngressURL    string
	InternalToken string
	Topic         string
	Debug         bool
	HTTPTimeout   time.Duration
}

type ingressPayload struct {
	RequestID     string                 `json:"request_id"`
	RunID         string                 `json:"run_id"`
	SenderStaffID string                 `json:"sender_staff_id"`
	Conversation  string                 `json:"conversation_id"`
	MessageID     string                 `json:"message_id"`
	Content       string                 `json:"content"`
	RawPayload    map[string]interface{} `json:"raw_payload"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("load config failed: %v", err)
	}

	if cfg.Debug {
		logger.SetLogger(logger.NewStdTestLoggerWithDebug())
	} else {
		logger.SetLogger(logger.NewStdTestLogger())
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	httpClient := &http.Client{Timeout: cfg.HTTPTimeout}
	streamClient := newStreamClient(cfg, httpClient)
	defer streamClient.Close()

	log.Printf("dingtalk stream worker started, ingress=%s", cfg.IngressURL)

	if err := streamClient.Start(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatalf("stream client stopped with error: %v", err)
	}

	// Stream SDK 的 Start 会异步返回，这里阻塞等待退出信号。
	<-ctx.Done()
	log.Printf("dingtalk stream worker stopping")
}

func newStreamClient(cfg config, httpClient *http.Client) *client.StreamClient {
	cli := client.NewStreamClient(
		client.WithAppCredential(client.NewAppCredentialConfig(cfg.AppKey, cfg.AppSecret)),
		client.WithAutoReconnect(true),
		client.WithUserAgent(client.NewDingtalkGoSDKUserAgent()),
		client.WithSubscription(
			"CALLBACK",
			cfg.Topic,
			chatbot.NewDefaultChatBotFrameHandler(func(ctx context.Context, data *chatbot.BotCallbackDataModel) ([]byte, error) {
				log.Printf(
					"chat callback received: msgId=%s sender=%s conv=%s msgtype=%s",
					strings.TrimSpace(data.MsgId),
					strings.TrimSpace(data.SenderStaffId),
					strings.TrimSpace(data.ConversationId),
					strings.TrimSpace(data.Msgtype),
				)

				payload, skip, err := buildIngressPayload(data)
				if err != nil {
					log.Printf("build ingress payload failed: %v", err)
					return nil, err
				}
				if skip {
					log.Printf("chat callback skipped: msgId=%s reason=non_text_or_empty", strings.TrimSpace(data.MsgId))
					return []byte("{}"), nil
				}

				if err := postToMen(ctx, httpClient, cfg, payload); err != nil {
					log.Printf("forward to men failed: msgId=%s err=%v", payload.MessageID, err)
					return nil, err
				}
				log.Printf("forward to men success: msgId=%s requestId=%s runId=%s", payload.MessageID, payload.RequestID, payload.RunID)

				return []byte("{}"), nil
			}).OnEventReceived,
		),
	)

	// 兜底接收 EVENT 类型，确保控制台“验证连接通道”场景可被正确 ACK。
	cli.RegisterAllEventRouter(func(ctx context.Context, df *payload.DataFrame) (*payload.DataFrameResponse, error) {
		header := event.NewEventHeaderFromDataFrame(df)
		log.Printf("stream event received: eventType=%s eventId=%s", header.EventType, header.EventId)

		resp := payload.NewSuccessDataFrameResponse()
		if err := resp.SetJson(event.NewEventProcessResultSuccess()); err != nil {
			return nil, err
		}
		return resp, nil
	})

	return cli
}

func loadConfig() (config, error) {
	cfg := config{
		AppKey:        strings.TrimSpace(os.Getenv("DINGTALK_APP_KEY")),
		AppSecret:     strings.TrimSpace(os.Getenv("DINGTALK_APP_SECRET")),
		IngressURL:    strings.TrimSpace(os.Getenv("MEN_INTERNAL_INGRESS_URL")),
		InternalToken: strings.TrimSpace(os.Getenv("DINGTALK_STREAM_INTERNAL_TOKEN")),
		Topic:         strings.TrimSpace(os.Getenv("DINGTALK_STREAM_TOPIC")),
		Debug:         strings.EqualFold(strings.TrimSpace(os.Getenv("DINGTALK_STREAM_DEBUG")), "true"),
		HTTPTimeout:   10 * time.Second,
	}

	if cfg.IngressURL == "" {
		cfg.IngressURL = defaultIngressURL
	}
	if cfg.Topic == "" {
		cfg.Topic = defaultTopic
	}

	if timeoutRaw := strings.TrimSpace(os.Getenv("MEN_INTERNAL_INGRESS_TIMEOUT_MS")); timeoutRaw != "" {
		var timeoutMs int
		if _, err := fmt.Sscanf(timeoutRaw, "%d", &timeoutMs); err == nil && timeoutMs > 0 {
			cfg.HTTPTimeout = time.Duration(timeoutMs) * time.Millisecond
		}
	}

	if cfg.AppKey == "" {
		return config{}, errors.New("DINGTALK_APP_KEY is required")
	}
	if cfg.AppSecret == "" {
		return config{}, errors.New("DINGTALK_APP_SECRET is required")
	}
	if cfg.InternalToken == "" {
		return config{}, errors.New("DINGTALK_STREAM_INTERNAL_TOKEN is required")
	}

	return cfg, nil
}

func buildIngressPayload(data *chatbot.BotCallbackDataModel) (ingressPayload, bool, error) {
	if data == nil {
		return ingressPayload{}, false, errors.New("stream callback data is nil")
	}

	content := strings.TrimSpace(data.Text.Content)
	if content == "" {
		// 非文本消息在 MVP 阶段先忽略，避免污染主链路。
		return ingressPayload{}, true, nil
	}

	if strings.TrimSpace(data.SenderStaffId) == "" {
		return ingressPayload{}, false, errors.New("senderStaffId is empty")
	}

	raw, err := toRawMap(data)
	if err != nil {
		return ingressPayload{}, false, err
	}

	messageID := strings.TrimSpace(data.MsgId)
	if messageID == "" {
		messageID = fmt.Sprintf("stream-%d", time.Now().UnixNano())
	}

	payload := ingressPayload{
		RequestID:     messageID,
		RunID:         "run-stream-" + messageID,
		SenderStaffID: strings.TrimSpace(data.SenderStaffId),
		Conversation:  strings.TrimSpace(data.ConversationId),
		MessageID:     messageID,
		Content:       content,
		RawPayload:    raw,
	}

	return payload, false, nil
}

func toRawMap(data *chatbot.BotCallbackDataModel) (map[string]interface{}, error) {
	buf, err := json.Marshal(data)
	if err != nil {
		return nil, err
	}

	var out map[string]interface{}
	if err := json.Unmarshal(buf, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func postToMen(ctx context.Context, httpClient *http.Client, cfg config, payload ingressPayload) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.IngressURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-men-internal-token", cfg.InternalToken)

	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("men ingress returned status=%d", resp.StatusCode)
	}

	return nil
}
