package main

import (
	"bytes"
	"log"
	"os"
	"path"
	"path/filepath"
	"strings"
	"text/template"
)

func eval(tmpl string, data interface{}) (string, error) {
	funcMap := template.FuncMap{
		"hyphenize": hyphenize,
		"basename":  basename,
		"indent":    indent,
		"contains":  strings.Contains,
	}
	t, err := template.New("inner").Funcs(funcMap).Parse(tmpl)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	err = t.Execute(&buf, data)
	if err != nil {
		return "", err
	}
	return buf.String(), nil
}
func generateFileFromTemplate(templateFile string, o interface{}, filePath string) error {
	funcMap := template.FuncMap{
		"hyphenize": hyphenize,
		"basename":  basename,
		"indent":    indent,
		"contains":  strings.Contains,
		"eval":      eval,
	}
	tmpl, err := template.New(templateFile).Funcs(funcMap).ParseFS(templateFS, "templates/*/*.yaml", "templates/*/*/*.yaml")
	if err != nil {
		return err
	}
	parentDir := filepath.Dir(filePath)
	err = os.MkdirAll(parentDir, os.ModePerm)
	if err != nil {
		log.Fatal("Error creating directory:", parentDir, err)
		return err
	}
	f, err := os.Create(filePath)
	if err != nil {
		return err
	}
	defer f.Close()
	err = tmpl.Execute(f, o)
	if err != nil {
		return err
	}
	return nil
}
func hyphenize(str string) string {
	return nameFieldInvalidCharPattern.ReplaceAllString(str, "-")
}

func basename(str string) string {
	return path.Base(str)
}

func indent(spaces int, v string) string {
	pad := strings.Repeat(" ", spaces)
	return pad + strings.Replace(v, "\n", "\n"+pad, -1)
}
