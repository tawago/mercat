//go:build js && wasm

package main

import (
	"syscall/js"

	"github.com/AlexanderGrooff/mermaid-ascii/pkg/diagram"
	"github.com/AlexanderGrooff/mermaid-ascii/pkg/render"
)

func main() {
	js.Global().Set("mermaidAscii", js.FuncOf(func(_ js.Value, args []js.Value) (out any) {
		defer func() {
			if r := recover(); r != nil {
				out = map[string]any{"error": "renderer crashed"}
			}
		}()
		cfg := diagram.DefaultConfig()
		cfg.MaxWidth = args[1].Int()
		s, _, err := render.RenderDiagramWithStatus(args[0].String(), cfg)
		if err != nil {
			return map[string]any{"error": err.Error()}
		}
		return map[string]any{"text": s}
	}))
	select {}
}
