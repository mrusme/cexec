package main

import (
  "bytes"
  "flag"
  "fmt"
  "os"
  "os/exec"
  "time"
  "strings"
  "crypto/sha256"
  "encoding/hex"
  "encoding/base64"

  "github.com/mrusme/cexec/backends"
)

func main() {
  var timeout int
  var backendName string

  flag.IntVar(&timeout, "t", 60, "caching timeout in seconds")
  flag.StringVar(&backendName, "b", "fs", "caching backend")

  flag.Parse()

  backend, err := backends.New(backendName)
  if err != nil {
    fmt.Fprintf(os.Stderr, err.Error())
    os.Exit(1)
  }
  defer backend.Uninitialize()

  command := flag.Args()

  if len(command) == 0 {
    fmt.Printf("Usage: cexec [options] command\n")
    flag.PrintDefaults()
    os.Exit(1)
  }

  cmdIdHash := sha256.Sum256([]byte(strings.Join(command, " ")))
  cmdId := hex.EncodeToString(cmdIdHash[:])

  var stdout, stderr bytes.Buffer
  var strout, strerr string
  hit, strerr, strout, _ := backend.Read(cmdId)

  if hit == false {
    cmd := exec.Command(command[0], command[1:]...)
    cmd.Stdout = &stdout
    cmd.Stderr = &stderr

    err = cmd.Run()
    if err != nil {
      fmt.Fprintf(os.Stderr, err.Error())
      os.Exit(1)
    }

    strout, strerr = base64.StdEncoding.EncodeToString(stdout.Bytes()), base64.StdEncoding.EncodeToString(stderr.Bytes())

    now := time.Now()
    expire := now.Add(time.Second * time.Duration(timeout))

    backend.Write(cmdId, strerr, strout, expire)
  } else {
    b64out, _ := base64.StdEncoding.DecodeString(strout)
    stdout.Write(b64out)
    b64err, _ := base64.StdEncoding.DecodeString(strerr)
    stderr.Write(b64err)
  }

  os.Stdout.Write(stdout.Bytes())
  os.Stderr.Write(stderr.Bytes())
}
