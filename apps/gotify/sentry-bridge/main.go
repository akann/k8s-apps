// sentry-gotify-bridge relays Sentry issue-alert webhooks to a Gotify /message endpoint.
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var (
	gotifyEndpoint = mustEnv("GOTIFY_ENDPOINT")
	gotifyToken    = mustEnv("GOTIFY_TOKEN")
	webhookSecret  = os.Getenv("SENTRY_WEBHOOK_SECRET") // HMAC secret from the Sentry internal integration; verification skipped if empty
	httpClient     = &http.Client{Timeout: 10 * time.Second}
)

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("missing required env var %s", key)
	}
	return v
}

type gotifyMessage struct {
	Title    string `json:"title"`
	Message  string `json:"message"`
	Priority int    `json:"priority"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/webhook/sentry", handleSentryWebhook)

	log.Printf("sentry-gotify-bridge listening on :%s (gotify=%s, signature verification=%v)", port, gotifyEndpoint, webhookSecret != "")
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

func handleSentryWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	if webhookSecret != "" {
		if !validSignature(body, r.Header.Get("Sentry-Hook-Signature")) {
			log.Printf("rejected webhook: bad signature")
			http.Error(w, "invalid signature", http.StatusUnauthorized)
			return
		}
	}

	// Sentry sends multiple resource types (installation, issue, event_alert, ...) to the
	// same URL. We only care about issue alert triggers.
	if resource := r.Header.Get("Sentry-Hook-Resource"); resource != "" && resource != "event_alert" {
		w.WriteHeader(http.StatusOK)
		return
	}

	msg, err := buildGotifyMessage(body)
	if err != nil {
		log.Printf("failed to parse sentry payload: %v", err)
		http.Error(w, "bad payload", http.StatusBadRequest)
		return
	}

	if err := sendToGotify(msg); err != nil {
		log.Printf("failed to forward to gotify: %v", err)
		http.Error(w, "failed to forward", http.StatusBadGateway)
		return
	}

	w.WriteHeader(http.StatusOK)
}

func validSignature(body []byte, signature string) bool {
	if signature == "" {
		return false
	}
	mac := hmac.New(sha256.New, []byte(webhookSecret))
	mac.Write(body)
	expected := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(signature))
}

// sentryEventAlertPayload covers the fields Sentry's "event_alert" webhook resource sends.
// Fields are intentionally optional/loose since Sentry's payload shape has varied across
// integration types; buildGotifyMessage() falls back gracefully when fields are missing.
type sentryEventAlertPayload struct {
	Action string `json:"action"`
	Data   struct {
		Event struct {
			EventID     string `json:"event_id"`
			Title       string `json:"title"`
			Message     string `json:"message"`
			Culprit     string `json:"culprit"`
			Level       string `json:"level"`
			Environment string `json:"environment"`
			Project     string `json:"project"`
			WebURL      string `json:"web_url"`
			IssueURL    string `json:"issue_url"`
			URL         string `json:"url"`
		} `json:"event"`
		TriggeredRule string `json:"triggered_rule"`
	} `json:"data"`
}

func buildGotifyMessage(body []byte) (gotifyMessage, error) {
	var payload sentryEventAlertPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		return gotifyMessage{}, err
	}

	ev := payload.Data.Event
	if ev.Title == "" && ev.Message == "" {
		// Unrecognized shape - forward a compact excerpt so nothing gets silently dropped.
		excerpt := string(body)
		if len(excerpt) > 500 {
			excerpt = excerpt[:500] + "..."
		}
		return gotifyMessage{
			Title:    "Sentry alert (unrecognized payload)",
			Message:  excerpt,
			Priority: 5,
		}, nil
	}

	title := ev.Title
	if title == "" {
		title = ev.Message
	}
	if ev.Project != "" {
		title = fmt.Sprintf("[%s] %s", ev.Project, title)
	}

	var lines []string
	if ev.Culprit != "" {
		lines = append(lines, ev.Culprit)
	}
	if ev.Environment != "" {
		lines = append(lines, fmt.Sprintf("environment: %s", ev.Environment))
	}
	link := firstNonEmpty(ev.WebURL, ev.IssueURL, ev.URL)
	if link != "" {
		lines = append(lines, link)
	}

	return gotifyMessage{
		Title:    title,
		Message:  strings.Join(lines, "\n"),
		Priority: priorityForLevel(ev.Level),
	}, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func priorityForLevel(level string) int {
	switch strings.ToLower(level) {
	case "fatal", "error":
		return 8
	case "warning":
		return 5
	default:
		return 4
	}
}

func sendToGotify(msg gotifyMessage) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPost, gotifyEndpoint+"?token="+gotifyToken, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("gotify returned %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}
