package backends

import (
  "errors"
  "time"
  "github.com/mrusme/cexec/backends/fs"
)

type Backend interface {
  Initialize() (error)
  Uninitialize() ()
  Write(identifier string, stderr string, stdout string, expire time.Time) (bool)
  Read(identifier string) (hit bool, stderr string, stdout string, expire time.Time)
}

func New(backendName string) (Backend, error) {
  var backend Backend

  switch(backendName) {
  case "fs":
    backend = new(fs.Fs)
  default:
    return nil, errors.New("No such backend")
  }

  err := backend.Initialize()
  if err != nil {
    return nil, err
  }

  return backend, nil
}
