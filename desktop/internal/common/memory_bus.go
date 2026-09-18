// Package common provides shared utility functions.
package common

// MemoryWarningBus provides a simple callback-based notification channel
// for memory pressure events. On desktop platforms this is typically a
// no-op, but the hook exists for platform-specific integrations.
type MemoryWarningBus struct {
	handlers []func(level int)
}

var defaultBus = &MemoryWarningBus{}

// Subscribe registers a handler to be called on memory pressure.
func Subscribe(handler func(level int)) {
	defaultBus.handlers = append(defaultBus.handlers, handler)
}

// Dispatch notifies all handlers of a memory pressure level.
// Level 1 = moderate, 2 = severe.
func Dispatch(level int) {
	for _, h := range defaultBus.handlers {
		h(level)
	}
}