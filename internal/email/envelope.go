package email

type Message struct {
	ID            string    `json:"id"`
	MessageID     string    `json:"message-id"`
	InReplyTo     []string  `json:"in-reply-to"`
	Flags         []Flag    `json:"flags"`
	Subject       string    `json:"subject"`
	From          []Address `json:"from"`
	To            []Address `json:"to"`
	Date          string    `json:"date"`
	Size          int       `json:"size"`
	HasAttachment *bool     `json:"has-attachment"`
}

type Flag struct {
	Raw  string `json:"raw"`
	IANA string `json:"iana"`
}

type Address struct {
	Name  *string `json:"name"`
	Email string  `json:"email"`
}
