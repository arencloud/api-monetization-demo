package main

import "testing"

func TestValidIdentifier(t *testing.T) {
	t.Parallel()
	tests := map[string]bool{
		"free":          true,
		"business":      true,
		"custom-tier":   true,
		"":              false,
		"Business":      false,
		"enterprise_2":  false,
		"invalid tier":  false,
		"../../secrets": false,
	}
	for value, expected := range tests {
		if actual := validIdentifier(value); actual != expected {
			t.Errorf("validIdentifier(%q)=%v, want %v", value, actual, expected)
		}
	}
}
