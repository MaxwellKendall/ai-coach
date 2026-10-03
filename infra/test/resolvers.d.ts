// The resolvers are plain APPSYNC_JS; tests call them with loose contexts.
declare module "../resolvers/*.js" {
  export function request(ctx: any): any;
  export function response(ctx: any): any;
}
