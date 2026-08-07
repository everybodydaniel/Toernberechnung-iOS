package main

import "testing"

func TestValidCrewspaceCrewRole(t *testing.T) {
	valid := []string{
		"Skipper",
		"Co-Skipper",
		"Navigation",
		"Wachführung",
		"Deck",
		"Sicherheit/Medizin",
		"Crew",
	}
	for _, role := range valid {
		if !validCrewspaceCrewRole(role) {
			t.Fatalf("expected role %q to be valid", role)
		}
	}

	invalid := []string{"", "owner", "member", "Kapitän", " crew "}
	for _, role := range invalid {
		if validCrewspaceCrewRole(role) {
			t.Fatalf("expected role %q to be invalid", role)
		}
	}
}
