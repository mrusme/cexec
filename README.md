cexec
-----

**Cached Exec**

[![Static Badge](https://img.shields.io/badge/Donate-Support_this_Project-orange?style=for-the-badge&logo=buymeacoffee&logoColor=%23ffffff&labelColor=%23333&link=https%3A%2F%2Fxn--gckvb8fzb.com%2Fsupport%2F)](https://xn--gckvb8fzb.com/support/) [![Static Badge](https://img.shields.io/badge/Join_on_Matrix-green?style=for-the-badge&logo=element&logoColor=%23ffffff&label=Chat&labelColor=%23333&color=%230DBD8B&link=https%3A%2F%2Fmatrix.to%2F%23%2F%2521PHlbgZTdrhjkCJrfVY%253Amatrix.org)](https://matrix.to/#/%21PHlbgZTdrhjkCJrfVY%3Amatrix.org)


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


