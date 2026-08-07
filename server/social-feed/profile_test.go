package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProfileMutationsRequireFirebaseToken(t *testing.T) {
	app := &application{}
	tests := []struct {
		name   string
		method string
		path   string
		body   string
	}{
		{
			name:   "complete profile",
			method: http.MethodPut,
			path:   "/profiles/skipper-a",
			body:   `{"skipper_id":"skipper-a","name":"A","boat_type":"Jolle"}`,
		},
		{
			name:   "boat type only",
			method: http.MethodPatch,
			path:   "/profiles/skipper-a/boat-type",
			body:   `{"boat_type":"Jolle"}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
			response := httptest.NewRecorder()

			app.handleProfileRoutes(response, request)

			if response.Code != http.StatusUnauthorized {
				t.Fatalf("expected status %d, got %d", http.StatusUnauthorized, response.Code)
			}
		})
	}
}

func TestProfileBelongsToAuthenticatedUser(t *testing.T) {
	user := firebaseUser{ID: "skipper-a"}
	if !profileBelongsToUser("skipper-a", user) {
		t.Fatal("matching Firebase subject and profile path must be accepted")
	}
	if profileBelongsToUser("skipper-b", user) {
		t.Fatal("a different profile path must be rejected")
	}
	if profileBelongsToUser("", user) {
		t.Fatal("an empty profile path must be rejected")
	}
}

func TestBoatTypePatchRejectsUnrelatedProfileFields(t *testing.T) {
	request := httptest.NewRequest(
		http.MethodPatch,
		"/profiles/skipper-a/boat-type",
		strings.NewReader(`{"boat_type":"Jolle","name":"Manipuliert"}`),
	)
	response := httptest.NewRecorder()
	var input updateBoatTypeRequest

	if err := readJSON(response, request, &input); err == nil {
		t.Fatal("boat-type PATCH must reject fields outside boat_type")
	}
}

func TestBoatTypeUpsertPreservesUnrelatedProfileFields(t *testing.T) {
	statement := strings.ToLower(strings.Join(strings.Fields(updateBoatTypeSQL), " "))
	if !strings.Contains(statement, "insert into skipper_profiles (id, name, boat_type)") {
		t.Fatal("boat-type mutation must upsert a missing profile")
	}
	if !strings.Contains(statement, "on conflict (id) do update set boat_type = excluded.boat_type") {
		t.Fatal("boat-type mutation must update boat_type on an existing profile")
	}

	for _, unrelatedAssignment := range []string{
		"name = excluded.name",
		"profile_image_url = excluded.profile_image_url",
		"home_harbour = excluded.home_harbour",
		"bio = excluded.bio",
	} {
		if strings.Contains(statement, unrelatedAssignment) {
			t.Fatalf("boat-type PATCH must not mutate unrelated field: %s", unrelatedAssignment)
		}
	}
}

func TestCommonHeadersAdvertisePatch(t *testing.T) {
	request := httptest.NewRequest(http.MethodOptions, "/profiles/skipper-a/boat-type", nil)
	response := httptest.NewRecorder()

	commonHeaders(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})).ServeHTTP(response, request)

	methods := response.Header().Get("Access-Control-Allow-Methods")
	if !strings.Contains(methods, http.MethodPatch) {
		t.Fatalf("CORS methods must include PATCH, got %q", methods)
	}
}
