---
status: accepted
---

# Voice Input transcribes on device as it is heard

[ADR 0036](0036-voice-input-sends-recordings-to-the-users-speech-service.md)
sends a finished recording to the user's speech service and lets the draft
take the text once. Voice Input now also offers On Device, Apple's dictation
model from iOS 26, whose text arrives while the user speaks. This amends
ADR 0036's "Upload, not streaming", "The draft takes the text once" and its
rejection of live partials; the rest of ADR 0036 stands.

## Decision

- **On Device is a service.** It is listed first from iOS 26 and needs no key
  or agreement, since nothing leaves the device. It uses
  `DictationTranscriber` with `progressiveShortDictation`, the keyboard
  dictation model, and passes Keywords as `contextualStrings`. The model is
  downloaded from Settings; a recording that finds it missing fails with a
  pointer there instead of waiting on a download.
- **One language per recording.** Every Speech transcriber takes one
  `Locale` (unchanged through the iOS 27.2 SDK). A Chinese locale keeps
  English words spoken inside Chinese; an English locale garbles Chinese, so
  the language is the one the user mostly speaks. On a Mac probe with
  synthetic zh + en speech, Keywords turned most misheard identifiers into
  exact ones.
- **Text is written into the draft as it is heard.** The recording's text
  holds one range of the draft, starting at the caret; each update replaces
  that range, and the final text ends it. ADR 0036's objections are met
  rather than avoided: Send and Stop already hide while recording; the editor
  keeps the keyboard but refuses typing, so the range stays where it was
  written and no store write lands on marked text; and the editor keeps the
  height it had when writing began, scrolling inside it, so the terminal
  above and its PTY keep their size until the text settles. Cancel withdraws
  the text. While the Composer is folded, the recording bar covers the draft
  and shows the end of the text in the waveform's place.
- **One capture for every service.** `AVAudioEngine`'s input tap is converted
  to 16 kHz mono 16-bit PCM, the format the dictation model asks for and the
  speech services take as WAV. The same audio feeds the device's model as it
  arrives and is kept in memory for upload; it is never written to a file.
- **Recording leaves other audio alone.** The session mixes with other apps,
  keeps Bluetooth A2DP output, and defaults to the speaker rather than the
  receiver, so music on a Bluetooth speaker or headphones keeps playing where
  it plays. Other audio can reach the microphone; that is accepted. The
  hands-free call profile stays excluded, as in ADR 0036.

## Considered Options

- **Partials in a preview, the draft taking the text once**: rejected. The
  recording bar is one line, and the risks that ADR 0036 named are handled
  by refusing typing and holding the height.
- **Two transcribers in parallel, one per language**: not now. iOS allows
  about two recognition instances and offers no way to merge them; a single
  Chinese locale already carries English words.
- **Streaming to a cloud service**: not now. No streaming protocol is shared
  across vendors, so it needs one adapter per vendor.

## Consequences

- The real engine runs only on a device; the Simulator lists locales but
  cannot analyze. Session tests use a scripted transcriber.
- No speech-recognition permission is asked, as the earlier Dictation
  shipped without it (ADR 0003). Add `NSSpeechRecognitionUsageDescription`
  only if a device shows it is needed.
- Accuracy on real speech with Heeler's vocabulary is still unmeasured.
