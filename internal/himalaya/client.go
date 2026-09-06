package himalaya

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"zenvoy/internal/email"
)

type commandRunner interface {
	Run(ctx context.Context, args ...string) ([]byte, error)
}

type execRunner struct {
	binary string
}

func (runner execRunner) Run(ctx context.Context, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runner.binary, args...)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		details := strings.TrimSpace(stderr.String())
		if details == "" {
			details = strings.TrimSpace(stdout.String())
		}

		if details == "" {
			return nil, fmt.Errorf("run %s: %w", runner.binary, err)
		}

		return nil, fmt.Errorf("run %s: %w: %s", runner.binary, err, details)
	}

	return stdout.Bytes(), nil
}

type Client struct {
	runner commandRunner
}

func NewClient() Client {
	return Client{
		runner: execRunner{binary: "himalaya"},
	}
}

func (client Client) ListMailboxes(ctx context.Context) (email.ListResponse, error) {
	output, err := client.runner.Run(
		ctx,
		"mailbox",
		"list",
		// "--counts",
		"--json",
		"--log-level",
		"off",
	)
	if err != nil {
		return email.ListResponse{}, fmt.Errorf("list Himalaya mailboxes: %w", err)
	}

	var response email.ListResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return email.ListResponse{}, fmt.Errorf("decode Himalaya mailbox JSON: %w", err)
	}

	return response, nil
}

func (client Client) ListEnvelopes(ctx context.Context) (email.EnvelopeListResponse, error) {
	output, err := client.runner.Run(
		ctx,
		"envelope",
		"list",
		"-s",
		"50",
		"--json",
	)
	if err != nil {
		return email.EnvelopeListResponse{}, fmt.Errorf("list Himalaya envelopes: %w", err)
	}

	var response email.EnvelopeListResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return email.EnvelopeListResponse{}, fmt.Errorf("decode Himalaya envelope JSON: %w", err)
	}

	return response, nil
}
