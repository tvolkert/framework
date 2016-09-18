library angel_framework.http.angel_base;

import 'dart:async';
import 'package:container/container.dart';
import 'routable.dart';

/// A function that asynchronously generates a view from the given path and data.
typedef Future<String> ViewGenerator(String path, [Map data]);

class AngelBase extends Routable {
  Container _container = new Container();
  /// A [Container] used to inject dependencies.
  Container get container => _container;

  /// A function that renders views.
  ///
  /// Called by [ResponseContext]@`render`.
  ViewGenerator viewGenerator = (String view,
      [Map data]) async => "No view engine has been configured yet.";
}