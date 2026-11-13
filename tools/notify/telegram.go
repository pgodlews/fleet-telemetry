package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// htmlEscape escapes characters that have special meaning inside Telegram's
// HTML parse_mode (`<`, `>`, `&`). Apply to every user-supplied or external
// string before interpolating into a message body. Trying to send a message
// containing a stray `<` triggers a Telegram 400 ("can't parse entities") and
// the whole message is lost.
func htmlEscape(s string) string {
	if !strings.ContainsAny(s, "<>&") {
		return s
	}
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")
	return r.Replace(s)
}

var telegramClient = &http.Client{Timeout: 30 * time.Second}

// telegramAPI is the Bot API base URL. A variable only so tests can point it
// at an unreachable address.
var telegramAPI = "https://api.telegram.org"

// ── Token-safe HTTP layer ────────────────────────────────────────────────────
//
// The bot token is part of every Bot API URL. Go's *url.Error embeds the full
// request URL in its message ("Post \"https://api.telegram.org/bot<token>/...\":
// dial tcp ..."), so wrapping a transport error with %w and logging it — or
// interpolating it into a chat reply — leaked the token. Every Telegram HTTP
// request goes through telegramDo, which is the only place a token-bearing URL
// is built and which returns errors with the URL removed and any remaining
// occurrence of the token masked.

// redactToken masks every occurrence of token in s.
func redactToken(s, token string) string {
	if token == "" {
		return s
	}
	return strings.ReplaceAll(s, token, "<redacted>")
}

// telegramError builds an error for operation op from err with the request
// URL dropped and the token masked. The returned error deliberately does not
// wrap err: unwrapping would hand the URL back to anyone who prints it.
func telegramError(op string, err error, token string) error {
	if err == nil {
		return nil
	}
	var ue *url.Error
	if errors.As(err, &ue) {
		// Keep the method ("Post") and the underlying cause; drop the URL.
		err = fmt.Errorf("%s: %v", ue.Op, ue.Err)
	}
	return errors.New(redactToken(op+": "+err.Error(), token))
}

// telegramDo sends one request. path is appended to the bot or file base:
// "sendMessage", "getUpdates?timeout=30", or for file=true the file path from
// getFile. body may be nil for GET.
func telegramDo(client *http.Client, token, httpMethod, path, contentType string, body io.Reader, file bool) (*http.Response, error) {
	base := "%s/bot%s/%s"
	if file {
		base = "%s/file/bot%s/%s"
	}
	op := strings.SplitN(path, "?", 2)[0]
	if file {
		op = "file download"
	}
	req, err := http.NewRequest(httpMethod, fmt.Sprintf(base, telegramAPI, token, path), body)
	if err != nil {
		return nil, telegramError(op, err, token)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, telegramError(op, err, token)
	}
	return resp, nil
}

// telegramPostJSON posts a JSON payload to a Bot API method and checks the
// response envelope.
func telegramPostJSON(token, method string, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	resp, err := telegramDo(telegramClient, token, http.MethodPost, method, "application/json", bytes.NewReader(body), false)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkTelegramResponse(resp); err != nil {
		return telegramError(method, err, token)
	}
	return nil
}

// tgResponse is the minimal Telegram Bot API response envelope.
type tgResponse struct {
	OK          bool            `json:"ok"`
	Description string          `json:"description"`
	Result      json.RawMessage `json:"result"`
}

// sendMessage sends a plain text message to the configured chat.
func sendMessage(token, chatID, text string) error {
	return telegramPostJSON(token, "sendMessage", map[string]string{
		"chat_id":    chatID,
		"text":       text,
		"parse_mode": "HTML",
	})
}

// captionLimit is Telegram's maximum caption length for sendPhoto, in UTF-16
// code units — which is how Telegram counts, not bytes and not runes.
const captionLimit = 1024

// truncateCaption shortens caption to Telegram's limit without splitting a
// rune or leaving a dangling HTML tag open.
//
// The limit was documented here but never enforced: user-defined place names
// and service descriptions are unbounded, and an over-long caption makes
// sendPhoto fail every time it is retried.
func truncateCaption(caption string) string {
	if utf16Len(caption) <= captionLimit {
		return caption
	}
	const ellipsis = "\n…"
	budget := captionLimit - utf16Len(ellipsis)

	// Cut at a rune boundary, then back off to the last tag-free position so
	// we never emit half of an <b> or a partially closed element.
	var out []rune
	used := 0
	for _, r := range caption {
		w := 1
		if r > 0xFFFF {
			w = 2
		}
		if used+w > budget {
			break
		}
		out = append(out, r)
		used += w
	}
	trimmed := string(out)
	if i := strings.LastIndexByte(trimmed, '<'); i >= 0 && !strings.ContainsRune(trimmed[i:], '>') {
		trimmed = trimmed[:i]
	}
	return trimmed + ellipsis
}

// utf16Len counts UTF-16 code units, the unit Telegram measures lengths in.
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		n++
		if r > 0xFFFF {
			n++
		}
	}
	return n
}

// sendPhoto sends a PNG image with a caption to the configured chat.
// The caption is truncated to Telegram's 1024-character limit.
func sendPhoto(token, chatID string, pngBytes []byte, caption string) error {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)

	if err := w.WriteField("chat_id", chatID); err != nil {
		return err
	}
	if err := w.WriteField("parse_mode", "HTML"); err != nil {
		return err
	}
	if caption != "" {
		if err := w.WriteField("caption", truncateCaption(caption)); err != nil {
			return err
		}
	}

	part, err := w.CreateFormFile("photo", "route.png")
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, bytes.NewReader(pngBytes)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}

	resp, err := telegramDo(telegramClient, token, http.MethodPost, "sendPhoto", w.FormDataContentType(), &buf, false)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if err := checkTelegramResponse(resp); err != nil {
		return telegramError("sendPhoto", err, token)
	}
	return nil
}

func checkTelegramResponse(resp *http.Response) error {
	var tgr tgResponse
	if err := json.NewDecoder(resp.Body).Decode(&tgr); err != nil {
		return fmt.Errorf("decode telegram response (HTTP %d): %w", resp.StatusCode, err)
	}
	if !tgr.OK {
		return fmt.Errorf("telegram error: %s", tgr.Description)
	}
	return nil
}

// ── Inline keyboard types ─────────────────────────────────────────────────────

// InlineKeyboardButton is a button shown inline below a message.
// CallbackData is sent back to the bot as a callback_query when pressed.
type InlineKeyboardButton struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data"`
}

// InlineKeyboardMarkup attaches inline buttons to a specific message.
type InlineKeyboardMarkup struct {
	InlineKeyboard [][]InlineKeyboardButton `json:"inline_keyboard"`
}

// telegramCallbackQuery is sent when a user presses an inline button.
type telegramCallbackQuery struct {
	ID      string          `json:"id"`
	Message telegramMessage `json:"message"` // the message the button was attached to
	Data    string          `json:"data"`    // the CallbackData string from the button
}

// ── Reply keyboard types ──────────────────────────────────────────────────────

// keyboardButton is a single button in a reply keyboard row.
// Set RequestLocation to true to make Telegram send the user's GPS automatically on press.
type keyboardButton struct {
	Text            string `json:"text"`
	RequestLocation bool   `json:"request_location,omitempty"`
}

// replyKeyboardMarkup describes a custom reply keyboard to show the user.
type replyKeyboardMarkup struct {
	Keyboard        [][]keyboardButton `json:"keyboard"`
	ResizeKeyboard  bool               `json:"resize_keyboard,omitempty"`
	OneTimeKeyboard bool               `json:"one_time_keyboard,omitempty"`
}

// replyKeyboardRemove instructs Telegram to hide the custom keyboard.
type replyKeyboardRemove struct {
	RemoveKeyboard bool `json:"remove_keyboard"`
}

// ── Long-polling types and helper ────────────────────────────────────────────

// telegramPhoto is one size variant of a photo sent by the user.
// Telegram sends photos as an array ordered from smallest to largest.
type telegramPhoto struct {
	FileID string `json:"file_id"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

// telegramDocument is a file (document/attachment) sent by the user.
type telegramDocument struct {
	FileID   string `json:"file_id"`
	FileName string `json:"file_name"`
	MimeType string `json:"mime_type"`
}

// telegramUpdate represents a single item from the getUpdates result array.
type telegramUpdate struct {
	UpdateID      int                    `json:"update_id"`
	Message       telegramMessage        `json:"message"`
	CallbackQuery *telegramCallbackQuery `json:"callback_query"`
}

// telegramLocation is a GPS coordinate sent by the user via Telegram's location feature.
type telegramLocation struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

// telegramMessage holds the message fields we care about.
type telegramMessage struct {
	MessageID int               `json:"message_id"`
	Text      string            `json:"text"`
	Chat      telegramChat      `json:"chat"`
	Photo     []telegramPhoto   `json:"photo"`    // set when user sends a photo; last entry is highest res
	Document  *telegramDocument `json:"document"` // set when user sends a file/document
	Location  *telegramLocation `json:"location"` // set when user shares a location
}

// telegramChat holds chat metadata.
type telegramChat struct {
	ID int64 `json:"id"`
}

// sendMessageWithKeyboard sends an HTML text message with a reply keyboard attached.
func sendMessageWithKeyboard(token, chatID, text string, kb replyKeyboardMarkup) error {
	return sendMessageWithKeyboardMode(token, chatID, text, kb, "HTML")
}

// sendMessageWithKeyboardPlain is the no-parse-mode variant used when the body
// includes user-controlled content that we do not want to risk having parsed
// as entities. Use this for error/confirmation messages on critical paths.
func sendMessageWithKeyboardPlain(token, chatID, text string, kb replyKeyboardMarkup) error {
	return sendMessageWithKeyboardMode(token, chatID, text, kb, "")
}

func sendMessageWithKeyboardMode(token, chatID, text string, kb replyKeyboardMarkup, parseMode string) error {
	payload := map[string]any{
		"chat_id":      chatID,
		"text":         text,
		"reply_markup": kb,
	}
	if parseMode != "" {
		payload["parse_mode"] = parseMode
	}
	return telegramPostJSON(token, "sendMessage", payload)
}

// sendMessageRemoveKeyboard sends a text message and removes the reply keyboard.
func sendMessageRemoveKeyboard(token, chatID, text string) error {
	return telegramPostJSON(token, "sendMessage", map[string]any{
		"chat_id":      chatID,
		"text":         text,
		"parse_mode":   "HTML",
		"reply_markup": replyKeyboardRemove{RemoveKeyboard: true},
	})
}

// telegramGetFilePath calls the getFile API and returns the server-side file path
// needed to construct the download URL.
func telegramGetFilePath(token, fileID string) (string, error) {
	resp, err := telegramDo(telegramClient, token, http.MethodGet,
		"getFile?file_id="+url.QueryEscape(fileID), "", nil, false)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var result struct {
		OK     bool `json:"ok"`
		Result struct {
			FilePath string `json:"file_path"`
		} `json:"result"`
		Description string `json:"description"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", telegramError("getFile", fmt.Errorf("decode: %v", err), token)
	}
	if !result.OK {
		return "", telegramError("getFile", errors.New(result.Description), token)
	}
	return result.Result.FilePath, nil
}

// sendMessageWithInlineKeyboard sends an HTML text message with inline buttons attached.
func sendMessageWithInlineKeyboard(token, chatID, text string, kb InlineKeyboardMarkup) error {
	return telegramPostJSON(token, "sendMessage", map[string]any{
		"chat_id":      chatID,
		"text":         text,
		"parse_mode":   "HTML",
		"reply_markup": kb,
	})
}

// editMessageText replaces the text and inline keyboard of an existing message.
// Used to update the config display in-place after a setting is toggled.
//
// Telegram returns "message is not modified" when the new content matches the
// current content byte-for-byte; that's a no-op we silently ignore.
func editMessageText(token, chatID string, messageID int, text string, kb InlineKeyboardMarkup) error {
	err := telegramPostJSON(token, "editMessageText", map[string]any{
		"chat_id":      chatID,
		"message_id":   messageID,
		"text":         text,
		"parse_mode":   "HTML",
		"reply_markup": kb,
	})
	if err != nil && strings.Contains(err.Error(), "message is not modified") {
		return nil
	}
	return err
}

// answerCallbackQuery must be called after every callback_query to remove the
// loading spinner from the button. text is shown as a brief toast (empty = silent).
func answerCallbackQuery(token, callbackQueryID, text string) error {
	return telegramPostJSON(token, "answerCallbackQuery", map[string]any{
		"callback_query_id": callbackQueryID,
		"text":              text,
	})
}

// updatesClient is reused across long-poll calls so the underlying HTTP
// connection can be kept alive.
var updatesClient = &http.Client{Timeout: time.Duration(commandLongPoll+10) * time.Second}

// telegramGetUpdates performs a long-poll call and returns incoming updates.
// offset should be set to the last update_id+1 to acknowledge previous updates.
// timeoutSecs is the long-poll timeout (Telegram holds the connection open for
// up to this many seconds if there are no new messages).
// Returns (nil, err) so the caller can log and back off on persistent failures.
func telegramGetUpdates(token string, offset, timeoutSecs int) ([]telegramUpdate, error) {
	resp, err := telegramDo(updatesClient, token, http.MethodGet,
		fmt.Sprintf("getUpdates?timeout=%d&offset=%d", timeoutSecs, offset), "", nil, false)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		OK          bool             `json:"ok"`
		Description string           `json:"description"`
		Result      []telegramUpdate `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, telegramError("getUpdates", fmt.Errorf("decode (HTTP %d): %v", resp.StatusCode, err), token)
	}
	if !result.OK {
		return nil, telegramError("getUpdates", errors.New(result.Description), token)
	}
	return result.Result, nil
}
