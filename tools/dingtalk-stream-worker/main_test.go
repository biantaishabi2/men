package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/open-dingtalk/dingtalk-stream-sdk-go/chatbot"
)

func TestBuildIngressPayload(t *testing.T) {
	data := &chatbot.BotCallbackDataModel{
		MsgId:          "msg-1",
		SenderStaffId:  "user-1",
		ConversationId: "cid-1",
		Text: chatbot.BotCallbackDataTextModel{
			Content: "hello",
		},
	}

	payload, skip, err := buildIngressPayload(data)
	if err != nil {
		t.Fatalf("buildIngressPayload error: %v", err)
	}
	if skip {
		t.Fatalf("buildIngressPayload should not skip")
	}
	if payload.RequestID != "msg-1" {
		t.Fatalf("unexpected request id: %s", payload.RequestID)
	}
	if payload.RunID != "run-stream-msg-1" {
		t.Fatalf("unexpected run id: %s", payload.RunID)
	}
	if payload.SenderStaffID != "user-1" {
		t.Fatalf("unexpected sender: %s", payload.SenderStaffID)
	}
	if payload.Content != "hello" {
		t.Fatalf("unexpected content: %s", payload.Content)
	}
}

func TestPostToMen(t *testing.T) {
	var gotToken string
	var gotPayload ingressPayload

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotToken = r.Header.Get("x-men-internal-token")
		defer r.Body.Close()
		if err := json.NewDecoder(r.Body).Decode(&gotPayload); err != nil {
			t.Fatalf("decode request body failed: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cfg := config{
		IngressURL:    srv.URL,
		InternalToken: "token-1",
	}

	payload := ingressPayload{
		RequestID:     "req-1",
		RunID:         "run-1",
		SenderStaffID: "u1",
		Content:       "hello",
	}

	client := &http.Client{Timeout: 2 * time.Second}
	if err := postToMen(context.Background(), client, cfg, payload); err != nil {
		t.Fatalf("postToMen failed: %v", err)
	}

	if gotToken != "token-1" {
		t.Fatalf("unexpected token header: %s", gotToken)
	}
	if gotPayload.RequestID != "req-1" || gotPayload.Content != "hello" {
		t.Fatalf("unexpected payload: %+v", gotPayload)
	}
}

