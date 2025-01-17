#' Subset rows using column values
#'
#' This is a method for the dplyr [filter()] generic. It generates the
#' `WHERE` clause of the SQL query.
#'
#' @inheritParams arrange.tbl_lazy
#' @inheritParams dplyr::filter
#' @param .preserve Not supported by this method.
#' @inherit arrange.tbl_lazy return
#' @examples
#' library(dplyr, warn.conflicts = FALSE)
#'
#' db <- memdb_frame(x = c(2, NA, 5, NA, 10), y = 1:5)
#' db %>% filter(x < 5) %>% show_query()
#' db %>% filter(is.na(x)) %>% show_query()
# registered onLoad
#' @importFrom dplyr filter
filter.tbl_lazy <- function(.data, ..., .preserve = FALSE) {
  if (!identical(.preserve, FALSE)) {
    abort("`.preserve` is not supported on database backends")
  }
  check_filter(...)

  dots <- partial_eval_dots(.data, ..., .named = FALSE)

  if (is_empty(dots)) {
    return(.data)
  }

  add_op_single("filter", .data, dots = dots)
}

#' @export
sql_build.op_filter <- function(op, con, ...) {
  vars <- op_vars(op$x)

  if (!uses_window_fun(op$dots, con)) {
    where_sql <- translate_sql_(op$dots, con, context = list(clause = "WHERE"))

    select_query(
      sql_build(op$x, con),
      where = where_sql
    )
  } else {
    # Do partial evaluation, then extract out window functions
    where <- translate_window_where_all(op$dots, ls(dbplyr_sql_translation(con)$window))

    # Convert where$expr back to a lazy dots object, and then
    # create mutate operation
    mutated <- sql_build(new_op_select(op$x, carry_over(vars, where$comp)), con = con)
    where_sql <- translate_sql_(where$expr, con = con, context = list(clause = "WHERE"))

    select_query(mutated, select = ident(vars), where = where_sql)
  }
}

check_filter <- function(...) {
  dots <- enquos(...)
  named <- have_name(dots)

  for (i in which(named)) {
    quo <- dots[[i]]

    # Unlike in `dplyr` named logical vectors do not make sense so they are
    # also not allowed
    expr <- quo_get_expr(quo)
    abort(c(
      glue::glue("Problem with `filter()` input `..{i}`."),
      x = glue::glue("Input `..{i}` is named."),
      i = glue::glue("This usually means that you've used `=` instead of `==`."),
      i = glue::glue("Did you mean `{name} == {as_label(expr)}`?", name = names(dots)[i])
    ))
  }
}
