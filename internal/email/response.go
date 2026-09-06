package email

type EnvelopeListResponse struct {
	Envelopes []Message `json:"envelopes"`
}

type InitialResponse struct {
	Mailboxes []Folder  `json:"mailboxes"`
	Envelopes []Message `json:"envelopes"`
}
