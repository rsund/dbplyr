capture_across <- function(data, x) {
  x <- enquo(x)
  partial_eval_across(get_expr(x), data, get_env(x))
}

partial_eval_across <- function(call, data, env) {
  call <- match.call(dplyr::across, call, expand.dots = FALSE, envir = env)
  across_setup(data, call, env, allow_rename = TRUE, fn = "across()")
}

capture_if_all <- function(data, x) {
  x <- enquo(x)
  partial_eval_if(get_expr(x), data, get_env(x))
}

partial_eval_if <- function(call, data, env, reduce = "&") {
  call <- match.call(dplyr::if_any, call, expand.dots = FALSE, envir = env)
  if (reduce == "&") {
    fn <- "if_all()"
  } else {
    fn <- "if_any()"
  }
  out <- across_setup(data, call, env, allow_rename = FALSE, fn = fn)
  Reduce(function(x, y) call2(reduce, x, y), out)
}

across_funs <- function(funs, env, data, dots, names_spec, fn) {
  if (is.null(funs)) {
    fns <- list(`1` = function(x, ...) x)
    names_spec <- names_spec %||% "{.col}"
    return(list(fns = fns, names = names_spec))
  } else if (is_symbol(funs)) {
    # unlike in `dtplyr` anonymous functions do not work (`is_function(funs)`)
    fns <- list(`1` = across_fun(funs, env, data, dots = dots, fn = fn))
    names_spec <- names_spec %||% "{.col}"
  } else if (is_call(funs, "~")) {
    fns <- list(`1` = across_fun(funs, env, data, dots = dots, fn = fn))
    names_spec <- names_spec %||% "{.col}"
  } else if (is_call(funs, "list")) {
    args <- call_args(funs)
    fns <- lapply(args, across_fun, env, data, dots = dots, fn = fn)
    names_spec <- names_spec %||% "{.col}_{.fn}"
  } else if (!is.null(env)) {
    # Try evaluating once, just in case
    funs <- eval(funs, env)
    return(across_funs(funs, NULL, dots = dots, names_spec = NULL, fn = fn))
  } else {
    abort("`.fns` argument to dbplyr::across() must be a NULL, a function, formula, or list")
  }

  list(fns = fns, names = names_spec)
}

across_fun <- function(fun, env, data, dots, fn) {
  # unlike in `dtplyr` anonymous functions do not work (`is_function(funs)` || is_call(fun, "function"))
  if (is_symbol(fun) || is_string(fun)) {
    function(x) call2(fun, x, !!!dots)
  } else if (is_call(fun, "~")) {
    if (!is_empty(dots)) {
      msg <- c(
        paste0("`dbplyr::", fn, "` does not support `...` when a purrr-style lambda is used in `.fns`."),
        i = "Use a lambda instead.",
        i = "Or inline them via a purrr-style lambda."
      )
      abort(msg)
    }
    call <- partial_eval_formula(fun, env, data, replace = quote(!!.x))
    function(x) inject(expr(!!call), child_env(empty_env(), .x = x, expr = rlang::expr))
  } else {
    abort(c(
      ".fns argument to dbplyr::across() must contain a function or a formula",
      x = paste0("Problem with ", expr_deparse(fun))
    ))
  }
}

partial_eval_formula <- function(x, env, data, replace = quote(!!.x)) {
  call <- f_rhs(x)
  call <- replace_dot(call, replace)
  if (is_call(call)) {
    call <- partial_eval_call(call, data, env)
  }
  call
}

across_setup <- function(data,
                         call,
                         env,
                         allow_rename,
                         fn) {
  tbl <- simulate_vars(data, drop_groups = TRUE)
  .cols <- call$.cols %||% expr(everything())
  locs <- tidyselect::eval_select(.cols, tbl, env = env, allow_rename = allow_rename)

  vars <- syms(names(tbl))[locs]
  if (allow_rename) {
    names_vars <- names(locs)
  } else {
    names_vars <- names(tbl)[locs]
  }

  dots <- lapply(call$..., partial_eval, data = data, env = env)
  names_spec <- eval(call$.names, env)
  funs_across_data <- across_funs(
    funs = call$.fns,
    env = env,
    data = data,
    dots = dots,
    names_spec = names_spec,
    fn = fn
  )
  fns_is_null <- funs_across_data$fns_is_null
  fns <- funs_across_data$fns
  names_spec <- funs_across_data$names

  # make sure fns has names, use number to replace unnamed
  names_fns <- names2(fns)
  empties <- which(names_fns == "")
  if (length(empties)) {
    names_fns[empties] <- empties
  }

  glue_mask <- across_glue_mask(env,
    .col = rep(names_vars, each = length(fns)),
    .fn  = rep(names_fns , length(vars))
  )
  names_out <- vctrs::vec_as_names(glue(names_spec, .envir = glue_mask), repair = "check_unique")

  across_apply_fns(vars, fns, names_out)
}

across_apply_fns <- function(vars, fns, names) {
  out <- vector("list", length(vars) * length(fns))
  out <- set_names(out, names)
  k <- 1
  for (i in seq_along(vars)) {
    for (j in seq_along(fns)) {
      out[[k]] <- exec(fns[[j]], vars[[i]])
      k <- k + 1
    }
  }
  out
}

across_glue_mask <- function(.col, .fn, .caller_env) {
  glue_mask <- env(.caller_env, .col = .col, .fn = .fn)
  # TODO: we can make these bindings louder later
  env_bind_active(
    glue_mask, col = function() glue_mask$.col, fn = function() glue_mask$.fn
  )
  glue_mask
}
