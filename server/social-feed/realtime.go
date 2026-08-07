package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	realtimeProtocolVersion       = 1
	realtimeQueueSize             = 64
	realtimeMaxConnectionsPerUser = 5
)

type realtimeEnvelope struct {
	Version      int                            `json:"version"`
	Type         string                         `json:"type"`
	EventID      string                         `json:"event_id"`
	OccurredAt   time.Time                      `json:"occurred_at"`
	Message      *crewspaceMessageResponse      `json:"message,omitempty"`
	Conversation *crewspaceConversationResponse `json:"conversation,omitempty"`
}

type realtimeClient struct {
	send   chan realtimeEnvelope
	cancel context.CancelFunc
}

type realtimeHub struct {
	mu          sync.Mutex
	connections map[string]map[*realtimeClient]struct{}
}

func newRealtimeHub() *realtimeHub {
	return &realtimeHub{connections: make(map[string]map[*realtimeClient]struct{})}
}

func (hub *realtimeHub) register(uid string, client *realtimeClient) bool {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	clients := hub.connections[uid]
	if clients == nil {
		clients = make(map[*realtimeClient]struct{})
		hub.connections[uid] = clients
	}
	if len(clients) >= realtimeMaxConnectionsPerUser {
		return false
	}
	clients[client] = struct{}{}
	return true
}

func (hub *realtimeHub) unregister(uid string, client *realtimeClient) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	clients := hub.connections[uid]
	delete(clients, client)
	if len(clients) == 0 {
		delete(hub.connections, uid)
	}
}

func (hub *realtimeHub) publish(uids []string, event realtimeEnvelope) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	seen := make(map[string]struct{}, len(uids))
	for _, uid := range uids {
		if _, exists := seen[uid]; exists {
			continue
		}
		seen[uid] = struct{}{}
		for client := range hub.connections[uid] {
			select {
			case client.send <- event:
			default:
				client.cancel()
			}
		}
	}
}

func (hub *realtimeHub) shutdown() {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	for _, clients := range hub.connections {
		for client := range clients {
			client.cancel()
		}
	}
	hub.connections = make(map[string]map[*realtimeClient]struct{})
}

func newRealtimeEnvelope(eventType string) realtimeEnvelope {
	eventID, err := newUUID()
	if err != nil {
		eventID = fmt.Sprintf("event-%d", time.Now().UnixNano())
	}
	return realtimeEnvelope{
		Version:    realtimeProtocolVersion,
		Type:       eventType,
		EventID:    eventID,
		OccurredAt: time.Now().UTC(),
	}
}

func (app *application) handleCrewspaceRealtime(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	if app.realtime == nil {
		writeError(w, http.StatusServiceUnavailable, "realtime ist nicht verfuegbar")
		return
	}
	connection, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	connection.SetReadLimit(4 << 10)

	ctx, cancel := context.WithCancel(r.Context())
	client := &realtimeClient{send: make(chan realtimeEnvelope, realtimeQueueSize), cancel: cancel}
	if !app.realtime.register(user.ID, client) {
		cancel()
		_ = connection.Close(websocket.StatusPolicyViolation, "connection limit reached")
		return
	}
	defer func() {
		cancel()
		app.realtime.unregister(user.ID, client)
		_ = connection.Close(websocket.StatusNormalClosure, "")
	}()

	readError := make(chan error, 1)
	go func() {
		for {
			if _, _, err := connection.Read(ctx); err != nil {
				readError <- err
				return
			}
		}
	}()

	if err := writeRealtimeEnvelope(ctx, connection, newRealtimeEnvelope("ready")); err != nil {
		return
	}
	pingTicker := time.NewTicker(25 * time.Second)
	defer pingTicker.Stop()

	for {
		select {
		case event := <-client.send:
			if err := writeRealtimeEnvelope(ctx, connection, event); err != nil {
				return
			}
		case <-pingTicker.C:
			pingContext, pingCancel := context.WithTimeout(ctx, 5*time.Second)
			err := connection.Ping(pingContext)
			pingCancel()
			if err != nil {
				return
			}
		case <-readError:
			return
		case <-ctx.Done():
			return
		}
	}
}

func writeRealtimeEnvelope(ctx context.Context, connection *websocket.Conn, event realtimeEnvelope) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return err
	}
	writeContext, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return connection.Write(writeContext, websocket.MessageText, payload)
}
