package main

// Properties of the source files that no behaviour test can show: no permanent
// deletion, no reading of file contents, no other programs, no network, no
// elevation. The scan covers every non-test file of the package, whatever its
// build constraint.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func tstSourceFiles(t *testing.T) []string {
	t.Helper()
	all, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, f := range all {
		if !strings.HasSuffix(f, "_test.go") {
			out = append(out, f)
		}
	}
	return out
}

func TestSourcesNeverDeletePermanentlyStartProgramsOrUseTheNetwork(t *testing.T) {
	files := tstSourceFiles(t)
	if len(files) == 0 {
		t.Fatal("the package has no source file besides the tests")
	}
	forbiddenImports := map[string]string{
		"os/exec": "starts programs", "net": "network", "net/http": "network", "net/url": "network",
		"net/rpc": "network", "net/smtp": "network", "C": "cgo", "plugin": "loads code",
	}
	forbiddenSelectors := map[string]bool{
		"DeleteFile": true, "DeleteFileW": true, "RemoveDirectory": true, "RemoveDirectoryW": true,
		"SHFileOperation": true, "SHFileOperationW": true, "DeleteItem": true,
		"ShellExecute": true, "ShellExecuteW": true, "ShellExecuteEx": true,
		"CreateProcess": true, "CreateProcessW": true, "StartProcess": true,
		"RemoveAll": true, "Unlink": true,
	}
	forbiddenOS := map[string]bool{"Remove": true, "RemoveAll": true, "Truncate": true, "WriteFile": true}
	readers := map[string]bool{"Open": true, "OpenFile": true, "ReadFile": true}
	forbiddenText := []string{"powershell", "pwsh", "explorer.exe", "cmd.exe", "remove-item", "http://", "https://", "requireadministrator", "runas"}

	fset := token.NewFileSet()
	for _, name := range files {
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		f, err := parser.ParseFile(fset, name, src, 0)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		for _, imp := range f.Imports {
			p, _ := strconv.Unquote(imp.Path.Value)
			if why, bad := forbiddenImports[p]; bad {
				t.Errorf("%s imports %q (%s)", name, p, why)
			}
		}
		isLog := strings.HasPrefix(filepath.Base(name), "oplog")
		ast.Inspect(f, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.SelectorExpr:
				pkg := ""
				if id, ok := x.X.(*ast.Ident); ok {
					pkg = id.Name
				}
				pos := fset.Position(x.Pos())
				if forbiddenSelectors[x.Sel.Name] {
					t.Errorf("%s: %s.%s is a permanent-deletion, program-start or shell call", pos, pkg, x.Sel.Name)
				}
				if pkg == "os" && forbiddenOS[x.Sel.Name] {
					t.Errorf("%s: os.%s changes or removes files", pos, x.Sel.Name)
				}
				if (pkg == "os" || pkg == "ioutil") && readers[x.Sel.Name] && !isLog {
					t.Errorf("%s: %s.%s opens or reads a file outside the log writer (oplog*.go)", pos, pkg, x.Sel.Name)
				}
			case *ast.BasicLit:
				if x.Kind == token.STRING {
					s, _ := strconv.Unquote(x.Value)
					low := strings.ToLower(s)
					for _, bad := range forbiddenText {
						if strings.Contains(low, bad) {
							t.Errorf("%s: the string %q mentions %q", fset.Position(x.Pos()), s, bad)
						}
					}
				}
			}
			return true
		})
	}
}

func TestSourcesDoNotReadTheProcessEnvironmentOutsideTheEntryPoint(t *testing.T) {
	files := tstSourceFiles(t)
	if len(files) == 0 {
		t.Fatal("the package has no source file besides the tests")
	}
	fset := token.NewFileSet()
	for _, name := range files {
		base := filepath.Base(name)
		src, _ := os.ReadFile(name)
		if strings.HasPrefix(base, "main") || strings.HasPrefix(base, "platform") || strings.Contains(string(src), "func main(") {
			continue // the entry point builds the environment map
		}
		f, err := parser.ParseFile(fset, name, src, 0)
		if err != nil {
			continue
		}
		ast.Inspect(f, func(n ast.Node) bool {
			if x, ok := n.(*ast.SelectorExpr); ok {
				if id, ok := x.X.(*ast.Ident); ok && id.Name == "os" && (x.Sel.Name == "Getenv" || x.Sel.Name == "Environ" || x.Sel.Name == "LookupEnv") {
					t.Errorf("%s: os.%s reads the real environment; the logic takes the environment map", fset.Position(x.Pos()), x.Sel.Name)
				}
			}
			return true
		})
	}
}
