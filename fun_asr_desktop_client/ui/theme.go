// Package ui provides the Fyne-based graphical user interface.
package ui

import (
	"image/color"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
)

// Colors.
var (
	Blue700      = color.NRGBA{R: 0x19, G: 0x76, B: 0xD2, A: 0xFF}
	RecordingRed = color.NRGBA{R: 0xD3, G: 0x2F, B: 0x2F, A: 0xFF}
	Green500     = color.NRGBA{R: 0x4C, G: 0xAF, B: 0x50, A: 0xFF}
)

type appTheme struct{}

func (t appTheme) Color(name fyne.ThemeColorName, variant fyne.ThemeVariant) color.Color {
	switch name {
	case theme.ColorNamePrimary:
		return Blue700
	case theme.ColorNameBackground:
		return color.NRGBA{R: 0xF5, G: 0xF5, B: 0xF5, A: 0xFF}
	default:
		return theme.DefaultTheme().Color(name, variant)
	}
}

func (t appTheme) Font(style fyne.TextStyle) fyne.Resource {
	return theme.DefaultTheme().Font(style)
}

func (t appTheme) Icon(name fyne.ThemeIconName) fyne.Resource {
	return theme.DefaultTheme().Icon(name)
}

func (t appTheme) Size(name fyne.ThemeSizeName) float32 {
	return theme.DefaultTheme().Size(name)
}
