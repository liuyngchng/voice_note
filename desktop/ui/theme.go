// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"image/color"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
)

// AppColorScheme defines the Material Design color palette for the voice note app.
var (
	Blue600      = color.NRGBA{R: 0x1E, G: 0x88, B: 0xE5, A: 0xFF}
	Blue700      = color.NRGBA{R: 0x19, G: 0x76, B: 0xD2, A: 0xFF}
	Blue800      = color.NRGBA{R: 0x15, G: 0x65, B: 0xC0, A: 0xFF}
	BlueGrey50   = color.NRGBA{R: 0xEC, G: 0xEF, B: 0xF1, A: 0xFF}
	BlueGrey900  = color.NRGBA{R: 0x26, G: 0x32, B: 0x38, A: 0xFF}
	Orange500    = color.NRGBA{R: 0xFF, G: 0x98, B: 0x00, A: 0xFF}
	Red500       = color.NRGBA{R: 0xF4, G: 0x43, B: 0x36, A: 0xFF}
	Green500     = color.NRGBA{R: 0x4C, G: 0xAF, B: 0x50, A: 0xFF}
	RecordingRed = color.NRGBA{R: 0xD3, G: 0x2F, B: 0x2F, A: 0xFF}
)

// voiceNoteTheme is the custom Fyne theme.
type voiceNoteTheme struct{}

func (t voiceNoteTheme) Color(name fyne.ThemeColorName, variant fyne.ThemeVariant) color.Color {
	switch name {
	case theme.ColorNamePrimary:
		return Blue700
	case theme.ColorNameBackground:
		return color.NRGBA{R: 0xF5, G: 0xF5, B: 0xF5, A: 0xFF}
	default:
		return theme.DefaultTheme().Color(name, variant)
	}
}

func (t voiceNoteTheme) Font(style fyne.TextStyle) fyne.Resource {
	return theme.DefaultTheme().Font(style)
}

func (t voiceNoteTheme) Icon(name fyne.ThemeIconName) fyne.Resource {
	return theme.DefaultTheme().Icon(name)
}

func (t voiceNoteTheme) Size(name fyne.ThemeSizeName) float32 {
	return theme.DefaultTheme().Size(name)
}
