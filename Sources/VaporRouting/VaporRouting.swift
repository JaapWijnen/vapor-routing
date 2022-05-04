import Vapor

extension Application {
  /// Mounts a router to the Vapor application.
  ///
  /// See ``VaporRouting`` for more information on usage.
  ///
  /// - Parameters:
  ///   - router: A parser-printer that works on inputs of `URLRequestData`.
  ///   - closure: A closure that takes a `Request` and the router's output as arguments.
  public func mount<R: Parser>(
    _ router: R,
    use closure: @escaping (Request, R.Output) async throws -> AsyncResponseEncodable
  ) where R.Input == URLRequestData {
    self.middleware.use(AsyncRoutingMiddleware(router: router, respond: closure))
  }

  @_disfavoredOverload
  public func _mount<R: Parser>(
    _ router: R,
    use closure: @escaping (Request, R.Output) -> EventLoopFuture<ResponseEncodable>
  ) where R.Input == URLRequestData {
    self.middleware.use(RoutingMiddleware(router: router, respond: closure))
  }
}

private struct RoutingMiddleware<Router: Parser>: Middleware
where Router.Input == URLRequestData {
  let router: Router
  let respond: (Request, Router.Output) -> EventLoopFuture<ResponseEncodable>

  public func respond(
    to request: Request,
    chainingTo next: Responder
  ) -> EventLoopFuture<Response> {

    guard let requestData = URLRequestData(request: request)
    else { return next.respond(to: request) }

    let route: Router.Output
    do {
      route = try self.router.parse(requestData)
      return self.respond(request, route)
        .flatMap { $0.encodeResponse(for: request) }
    } catch let routingError {
      return next.respond(to: request)
        .flatMapError { error in
          request.logger.info("\(routingError)")

          guard request.application.environment == .development
          else { return request.eventLoop.makeFailedFuture(error) }

          return request.eventLoop.makeSucceededFuture(
            Response(status: .notFound, body: .init(string: "Routing \(routingError)"))
          )
        }
    }
  }
}

private struct AsyncRoutingMiddleware<Router: Parser>: AsyncMiddleware
where Router.Input == URLRequestData {
  let router: Router
  let respond: (Request, Router.Output) async throws -> AsyncResponseEncodable

  public func respond(
    to request: Request,
    chainingTo next: AsyncResponder
  ) async throws -> Response {

    guard let requestData = URLRequestData(request: request)
    else { return try await next.respond(to: request) }

    let route: Router.Output
    do {
      route = try self.router.parse(requestData)
      return try await self.respond(request, route).encodeResponse(for: request)
    } catch let routingError {
      do {
        return try await next.respond(to: request)
      } catch {
        request.logger.info("\(routingError)")

        guard request.application.environment == .development
        else { throw error }

        return Response(status: .notFound, body: .init(string: "Routing \(routingError)"))
      }
    }
  }
}
