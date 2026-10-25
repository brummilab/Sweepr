package main

import (
	"strings"
	"testing"
)

func TestMalformedProxyNeverEchoesCredentials(t *testing.T) {
	for _, raw := range []string{"http://user:secret%ZZ@host:80", "http://user:secret@bad host:80"} {
		got := collectProxyFromEnv(func(key string) string {
			if key == "https_proxy" {
				return raw
			}
			return ""
		})
		if strings.Contains(got.Host, "secret") || strings.Contains(got.Host, "user") {
			t.Fatalf("credentials leaked: %+v", got)
		}
	}
	got := collectProxyFromEnv(func(key string) string {
		if key == "https_proxy" {
			return "http://user:secret@host:80"
		}
		return ""
	})
	if got.Host != "host:80" || !got.Enabled {
		t.Fatalf("valid proxy changed: %+v", got)
	}
}

func TestWindowsProxySettingsNeverEchoCredentials(t *testing.T) {
	for _, raw := range []string{"user:secret@host:80", "http=user:secret@host:80", "https=http://user:secret%ZZ@host:80"} {
		got := proxyFromInternetSettings(true, raw, "")
		if strings.Contains(got.Host, "secret") || strings.Contains(got.Host, "user") {
			t.Fatalf("credentials leaked: %+v", got)
		}
	}
}
