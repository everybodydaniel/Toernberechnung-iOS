package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/auth"
	"firebase.google.com/go/v4/messaging"
)

type firebaseIdentityProvider interface {
	VerifyIDToken(context.Context, string) (firebaseUser, error)
	LookupUser(context.Context, string) (firebaseUser, error)
}

type pushNotification struct {
	InstallationIDs []string
	Title           string
	Body            string
	Data            map[string]string
}

type pushNotificationSender interface {
	Send(context.Context, pushNotification) ([]string, error)
}

type firebaseAdminClient struct {
	auth      *auth.Client
	messaging *messaging.Client
}

const firebaseMulticastBatchSize = 500

func newFirebaseAdminClient(ctx context.Context, projectID string) (*firebaseAdminClient, error) {
	projectID = strings.TrimSpace(projectID)
	if projectID == "" {
		return nil, errors.New("firebase project id is required")
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID})
	if err != nil {
		return nil, fmt.Errorf("initialize firebase app: %w", err)
	}
	authClient, err := app.Auth(ctx)
	if err != nil {
		return nil, fmt.Errorf("initialize firebase auth: %w", err)
	}
	messagingClient, err := app.Messaging(ctx)
	if err != nil {
		return nil, fmt.Errorf("initialize firebase messaging: %w", err)
	}
	return &firebaseAdminClient{auth: authClient, messaging: messagingClient}, nil
}

func (client *firebaseAdminClient) VerifyIDToken(ctx context.Context, rawToken string) (firebaseUser, error) {
	token, err := client.auth.VerifyIDToken(ctx, strings.TrimSpace(rawToken))
	if err != nil {
		return firebaseUser{}, err
	}
	name, _ := token.Claims["name"].(string)
	email, _ := token.Claims["email"].(string)
	return firebaseUser{
		ID:    token.UID,
		Name:  strings.TrimSpace(name),
		Email: strings.TrimSpace(email),
	}, nil
}

func (client *firebaseAdminClient) LookupUser(ctx context.Context, uid string) (firebaseUser, error) {
	record, err := client.auth.GetUser(ctx, strings.TrimSpace(uid))
	if err != nil {
		return firebaseUser{}, err
	}
	return firebaseUser{
		ID:    record.UID,
		Name:  strings.TrimSpace(record.DisplayName),
		Email: strings.TrimSpace(record.Email),
	}, nil
}

func (client *firebaseAdminClient) Send(ctx context.Context, notification pushNotification) ([]string, error) {
	if len(notification.InstallationIDs) == 0 {
		return nil, nil
	}
	invalid := make([]string, 0)
	var firstError error
	for _, installationIDs := range chunkInstallationIDs(
		notification.InstallationIDs,
		firebaseMulticastBatchSize,
	) {
		response, err := client.messaging.SendEachForMulticast(
			ctx,
			firebaseMulticastMessage(notification, installationIDs),
		)
		if err != nil {
			if firstError == nil {
				firstError = err
			}
			continue
		}
		for index, result := range response.Responses {
			if result.Success {
				continue
			}
			if messaging.IsUnregistered(result.Error) {
				invalid = append(invalid, installationIDs[index])
				continue
			}
			if firstError == nil {
				firstError = result.Error
			}
		}
	}
	return invalid, firstError
}

func firebaseMulticastMessage(
	notification pushNotification,
	installationIDs []string,
) *messaging.MulticastMessage {
	return &messaging.MulticastMessage{
		Fids: installationIDs,
		Data: notification.Data,
		Android: &messaging.AndroidConfig{
			Priority: "high",
		},
		APNS: &messaging.APNSConfig{
			Headers: map[string]string{
				"apns-priority":  "10",
				"apns-push-type": "alert",
			},
			Payload: &messaging.APNSPayload{
				Aps: &messaging.Aps{
					Alert: &messaging.ApsAlert{
						Title: notification.Title,
						Body:  notification.Body,
					},
					Sound: "default",
				},
			},
		},
	}
}

func chunkInstallationIDs(values []string, size int) [][]string {
	if size < 1 {
		return nil
	}
	chunks := make([][]string, 0, (len(values)+size-1)/size)
	for start := 0; start < len(values); start += size {
		end := min(start+size, len(values))
		chunks = append(chunks, values[start:end])
	}
	return chunks
}
