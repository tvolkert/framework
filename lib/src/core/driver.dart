import 'dart:async';
import 'dart:convert';
import 'dart:io' show stderr, Cookie;
import 'package:angel_http_exception/angel_http_exception.dart';
import 'package:angel_route/angel_route.dart';
import 'package:combinator/combinator.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:tuple/tuple.dart';
import 'core.dart';

/// Base driver class for Angel implementations.
///
/// Powers both AngelHttp and AngelHttp2.
abstract class Driver<
    Request,
    Response,
    Server extends Stream<Request>,
    RequestContextType extends RequestContext,
    ResponseContextType extends ResponseContext> {
  final Angel app;
  final bool useZone;
  bool _closed = false;
  Server _server;
  StreamSubscription<Request> _sub;

  /// The function used to bind this instance to a server..
  final Future<Server> Function(dynamic, int) serverGenerator;

  Driver(this.app, this.serverGenerator, {this.useZone: true});

  /// The path at which this server is listening for requests.
  Uri get uri;

  /// The native server running this instance.
  Server get server => _server;

  /// Starts, and returns the server.
  Future<Server> startServer([address, int port]) {
    var host = address ?? '127.0.0.1';
    return serverGenerator(host, port ?? 0).then((server) {
      _server = server;
      return Future.wait(app.startupHooks.map(app.configure)).then((_) {
        app.optimizeForProduction();
        _sub = server.listen((request) =>
            handleRawRequest(request, createResponseFromRawRequest(request)));
        return _server;
      });
    });
  }

  /// Shuts down the underlying server.
  Future<Server> close() {
    if (_closed) return new Future.value(_server);
    _closed = true;
    _sub?.cancel();
    return app.close().then((_) =>
        Future.wait(app.shutdownHooks.map(app.configure)).then((_) => _server));
  }

  Future<RequestContextType> createRequestContext(
      Request request, Response response);

  Future<ResponseContextType> createResponseContext(
      Request request, Response response,
      [RequestContextType correspondingRequest]);

  void setHeader(Response response, String key, String value);

  void setContentLength(Response response, int length);

  void setChunkedEncoding(Response response, bool value);

  void setStatusCode(Response response, int value);

  void addCookies(Response response, Iterable<Cookie> cookies);

  void writeStringToResponse(Response response, String value);

  void writeToResponse(Response response, List<int> data);

  Uri getUriFromRequest(Request request);

  Future closeResponse(Response response);

  Response createResponseFromRawRequest(Request request);

  /// Handles a single request.
  Future handleRawRequest(Request request, Response response) {
    return createRequestContext(request, response).then((req) {
      return createResponseContext(request, response, req).then((res) {
        handle() {
          var path = req.path;
          if (path == '/') path = '';

          Tuple3<List, Map<String, dynamic>, ParseResult<Map<String, dynamic>>>
              resolveTuple() {
            Router r = app.optimizedRouter;
            var resolved =
                r.resolveAbsolute(path, method: req.method, strip: false);

            return new Tuple3(
              new MiddlewarePipeline(resolved).handlers,
              resolved.fold<Map<String, dynamic>>(
                  <String, dynamic>{}, (out, r) => out..addAll(r.allParams)),
              resolved.isEmpty ? null : resolved.first.parseResult,
            );
          }

          var cacheKey = req.method + path;
          var tuple = app.isProduction
              ? app.handlerCache.putIfAbsent(cacheKey, resolveTuple)
              : resolveTuple();

          req.params.addAll(tuple.item2);

          req.container.registerSingleton<ParseResult<Map<String, dynamic>>>(
              tuple.item3);
          req.container.registerSingleton<ParseResult>(tuple.item3);

          if (!app.isProduction && app.logger != null) {
            req.container
                .registerSingleton<Stopwatch>(new Stopwatch()..start());
          }

          var pipeline = tuple.item1;

          Future Function() runPipeline;

          for (var handler in pipeline) {
            if (handler == null) break;

            if (runPipeline == null)
              runPipeline = () =>
                  Future.sync(() => app.executeHandler(handler, req, res));
            else {
              var current = runPipeline;
              runPipeline = () => current().then((result) => !res.isOpen
                  ? new Future.value(result)
                  : app.executeHandler(handler, req, res));
            }
          }

          return runPipeline == null
              ? sendResponse(request, response, req, res)
              : runPipeline()
                  .then((_) => sendResponse(request, response, req, res));
        }

        if (useZone == false) {
          Future f;

          try {
            f = handle();
          } catch (e, st) {
            f = Future.error(e, st);
          }

          return f.catchError((e, StackTrace st) {
            if (e is FormatException)
              throw new AngelHttpException.badRequest(message: e.message)
                ..stackTrace = st;
            throw new AngelHttpException(e,
                stackTrace: st,
                statusCode: 500,
                message: e?.toString() ?? '500 Internal Server Error');
          }, test: (e) => e is! AngelHttpException).catchError(
              (ee, StackTrace st) {
            var e = ee as AngelHttpException;

            if (app.logger != null) {
              var error = e.error ?? e;
              var trace =
                  new Trace.from(e.stackTrace ?? StackTrace.current).terse;
              app.logger.severe(e.message ?? e.toString(), error, trace);
            }

            return handleAngelHttpException(
                e, e.stackTrace ?? st, req, res, request, response);
          });
        } else {
          var zoneSpec = new ZoneSpecification(
            print: (self, parent, zone, line) {
              if (app.logger != null)
                app.logger.info(line);
              else
                parent.print(zone, line);
            },
            handleUncaughtError: (self, parent, zone, error, stackTrace) {
              var trace =
                  new Trace.from(stackTrace ?? StackTrace.current).terse;

              return new Future(() {
                AngelHttpException e;

                if (error is FormatException) {
                  e = new AngelHttpException.badRequest(message: error.message);
                } else if (error is AngelHttpException) {
                  e = error;
                } else {
                  e = new AngelHttpException(error,
                      stackTrace: stackTrace,
                      message:
                          error?.toString() ?? '500 Internal Server Error');
                }

                if (app.logger != null) {
                  app.logger.severe(e.message ?? e.toString(), error, trace);
                }

                return handleAngelHttpException(
                    e, trace, req, res, request, response);
              }).catchError((e, StackTrace st) {
                var trace = new Trace.from(st ?? StackTrace.current).terse;
                var uri = getUriFromRequest(request);
                closeResponse(response);
                // Ideally, we won't be in a position where an absolutely fatal error occurs,
                // but if so, we'll need to log it.
                if (app.logger != null) {
                  app.logger.severe(
                      'Fatal error occurred when processing $uri.', e, trace);
                } else {
                  stderr
                    ..writeln('Fatal error occurred when processing '
                        '$uri:')
                    ..writeln(e)
                    ..writeln(trace);
                }
              });
            },
          );

          var zone = Zone.current.fork(specification: zoneSpec);
          req.container.registerSingleton<Zone>(zone);
          req.container.registerSingleton<ZoneSpecification>(zoneSpec);

          // If a synchronous error is thrown, it's not caught by `zone.run`,
          // so use a try/catch, and recover when need be.

          try {
            return zone.run(handle);
          } catch (e, st) {
            zone.handleUncaughtError(e, st);
            return Future.value();
          }
        }
      });
    });
  }

  /// Handles an [AngelHttpException].
  Future handleAngelHttpException(
      AngelHttpException e,
      StackTrace st,
      RequestContext req,
      ResponseContext res,
      Request request,
      Response response,
      {bool ignoreFinalizers: false}) {
    if (req == null || res == null) {
      try {
        app.logger?.severe(e, st);
        setStatusCode(response, 500);
        writeStringToResponse(response, '500 Internal Server Error');
        closeResponse(response);
      } finally {
        return null;
      }
    }

    Future handleError;

    if (!res.isOpen)
      handleError = new Future.value();
    else {
      res.statusCode = e.statusCode;
      handleError =
          new Future.sync(() => app.errorHandler(e, req, res)).then((result) {
        return app.executeHandler(result, req, res).then((_) => res.close());
      });
    }

    return handleError.then((_) => sendResponse(request, response, req, res,
        ignoreFinalizers: ignoreFinalizers == true));
  }

  /// Sends a response.
  Future sendResponse(Request request, Response response, RequestContext req,
      ResponseContext res,
      {bool ignoreFinalizers: false}) {
    void _cleanup(_) {
      if (!app.isProduction && app.logger != null) {
        var sw = req.container.make<Stopwatch>();
        app.logger.info(
            "${res.statusCode} ${req.method} ${req.uri} (${sw?.elapsedMilliseconds ?? 'unknown'} ms)");
      }
    }

    if (!res.isBuffered) return res.close().then(_cleanup);

    Future finalizers = ignoreFinalizers == true
        ? new Future.value()
        : app.responseFinalizers.fold<Future>(
            new Future.value(), (out, f) => out.then((_) => f(req, res)));

    return finalizers.then((_) {
      if (res.isOpen) res.close();

      for (var key in res.headers.keys) {
        setHeader(response, key, res.headers[key]);
      }

      setContentLength(response, res.buffer.length);
      setChunkedEncoding(response, res.chunked ?? true);

      List<int> outputBuffer = res.buffer.toBytes();

      if (res.encoders.isNotEmpty) {
        var allowedEncodings = req.headers
            .value('accept-encoding')
            ?.split(',')
            ?.map((s) => s.trim())
            ?.where((s) => s.isNotEmpty)
            ?.map((str) {
          // Ignore quality specifications in accept-encoding
          // ex. gzip;q=0.8
          if (!str.contains(';')) return str;
          return str.split(';')[0];
        });

        if (allowedEncodings != null) {
          for (var encodingName in allowedEncodings) {
            Converter<List<int>, List<int>> encoder;
            String key = encodingName;

            if (res.encoders.containsKey(encodingName))
              encoder = res.encoders[encodingName];
            else if (encodingName == '*') {
              encoder = res.encoders[key = res.encoders.keys.first];
            }

            if (encoder != null) {
              setHeader(response, 'content-encoding', key);
              outputBuffer = res.encoders[key].convert(outputBuffer);
              setContentLength(response, outputBuffer.length);
              break;
            }
          }
        }
      }

      setStatusCode(response, res.statusCode);
      addCookies(response, res.cookies);
      writeToResponse(response, outputBuffer);
      return closeResponse(response).then(_cleanup);
    });
  }
}