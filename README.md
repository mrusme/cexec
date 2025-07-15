cexec
-----

**Cached Exec**

[<img src="https://xn--gckvb8fzb.com/images/chatroom.png" width="275">](https://xn--gckvb8fzb.com/contact/)


`cexec` allows to run commands and cache their output for a specific amount of
time, so that re-running the command won't actually run it but instead return
the cached output.

`cexec` will use the path specified in `XDG_CACHE_HOME` to store its cache.
Please make sure it is exported in your ENV.


## Examples

Run a program and cache its output for 60 seconds (default setting):

```sh
cexec echo Hello World
```

Run a program and cache its output for 120 seconds:

```sh
cexec -t 120 echo Hello World
```


