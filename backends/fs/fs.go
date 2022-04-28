package fs

import (
  "errors"
  "fmt"
  "os"
  "path/filepath"
  "time"

  "github.com/tidwall/buntdb"
)

type Fs struct {
  db            *buntdb.DB
}

func(backend *Fs) Initialize() (error) {
  var err error

  cachedir := os.Getenv("XDG_CACHE_HOME")
  if cachedir == "" {
    return errors.New("XDG_CACHE_HOME not set")
  }
  cachedb := filepath.Join(cachedir, "cexec.db")

  backend.db, err = buntdb.Open(cachedb)
  if err != nil {
    return err
  } 
  return nil
}

func(backend *Fs) Uninitialize() () {
  backend.db.Close()
}

func(backend *Fs) Write(identifier string, stderr string, stdout string, expire time.Time) (bool) {
  err := backend.db.Update(func(tx *buntdb.Tx) error {
    tx.Set(fmt.Sprintf("%s:stderr", identifier), stderr, nil)
    tx.Set(fmt.Sprintf("%s:stdout", identifier), stdout, nil)
    tx.Set(fmt.Sprintf("%s:expire", identifier), expire.Format("2006-01-02 15:04:05.999999999 -0700 MST"), nil)
    return nil
  })
  if err != nil {
    return false
  }
  return true
}

func(backend *Fs) Read(identifier string) (bool, string, string, time.Time) {
  var hit bool = false
  var stderr string
  var stdout string
  var expire time.Time

  err := backend.db.View(func(tx *buntdb.Tx) error {
    var err error
    stderr, err = tx.Get(fmt.Sprintf("%s:stderr", identifier))
    if err != nil { return err }

    stdout, err = tx.Get(fmt.Sprintf("%s:stdout", identifier))
    if err != nil { return err }

    exp, err := tx.Get(fmt.Sprintf("%s:expire", identifier))
    if err != nil { return err }
    expire, err = time.Parse("2006-01-02 15:04:05.999999999 -0700 MST", exp)
    if err != nil { return err }

    return nil
  })
  if err != nil {
    return hit, stderr, stdout, expire
  }


  now := time.Now()
  if now.Before(expire) {
    hit = true
  }

  return hit, stderr, stdout, expire
}

