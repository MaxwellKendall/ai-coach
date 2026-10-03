// Before/after code shared by every pipeline resolver: the functions do the work.
export function request() {
  return {};
}

export function response(ctx) {
  return ctx.prev.result;
}
