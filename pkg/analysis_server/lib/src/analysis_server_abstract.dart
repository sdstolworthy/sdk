// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:core';

import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/collections.dart';
import 'package:analysis_server/src/context_manager.dart';
import 'package:analysis_server/src/domains/completion/available_suggestions.dart';
import 'package:analysis_server/src/server/diagnostic_server.dart';
import 'package:analysis_server/src/services/correction/namespace.dart';
import 'package:analysis_server/src/services/search/element_visitors.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/exception/exception.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/driver.dart' as nd;
import 'package:analyzer/src/dart/analysis/file_byte_store.dart'
    show EvictingFileByteStore;
import 'package:analyzer/src/dart/analysis/file_state.dart' as nd;
import 'package:analyzer/src/dart/analysis/status.dart' as nd;
import 'package:analyzer/src/dart/ast/element_locator.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/dartdoc/dartdoc_directive_info.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/services/available_declarations.dart';
import 'package:analyzer/src/util/glob.dart';

/// Implementations of [AbstractAnalysisServer] implement a server that listens
/// on a [CommunicationChannel] for analysis messages and process them.
abstract class AbstractAnalysisServer {
  /// The options of this server instance.
  AnalysisServerOptions options;

  /// The [ContextManager] that handles the mapping from analysis roots to
  /// context directories.
  ContextManager contextManager;

  ByteStore byteStore;

  nd.AnalysisDriverScheduler analysisDriverScheduler;

  DeclarationsTracker declarationsTracker;
  DeclarationsTrackerData declarationsTrackerData;

  /// The DiagnosticServer for this AnalysisServer. If available, it can be used
  /// to start an http diagnostics server or return the port for an existing
  /// server.
  final DiagnosticServer diagnosticServer;

  /// A [RecentBuffer] of the most recent exceptions encountered by the analysis
  /// server.
  final RecentBuffer<ServerException> exceptions = new RecentBuffer(10);

  /// Performance information after initial analysis is complete
  /// or `null` if the initial analysis is not yet complete
  ServerPerformance performanceAfterStartup;

  /// The class into which performance information is currently being recorded.
  /// During startup, this will be the same as [performanceDuringStartup]
  /// and after startup is complete, this switches to [performanceAfterStartup].
  ServerPerformance performance;

  /// Performance information before initial analysis is complete.
  final ServerPerformance performanceDuringStartup = new ServerPerformance();

  /// The set of the files that are currently priority.
  final Set<String> priorityFiles = new Set<String>();

  final List<String> analyzableFilePatterns = <String>[
    '**/*.${AnalysisEngine.SUFFIX_DART}',
    '**/*.${AnalysisEngine.SUFFIX_HTML}',
    '**/*.${AnalysisEngine.SUFFIX_HTM}',
    '**/${AnalysisEngine.ANALYSIS_OPTIONS_FILE}',
    '**/${AnalysisEngine.ANALYSIS_OPTIONS_YAML_FILE}',
    '**/${AnalysisEngine.PUBSPEC_YAML_FILE}',
    '**/${AnalysisEngine.ANDROID_MANIFEST_FILE}'
  ];

  /// The [ResourceProvider] using which paths are converted into [Resource]s.
  final OverlayResourceProvider resourceProvider;

  /// The next modification stamp for a changed file in the [resourceProvider].
  int overlayModificationStamp = 0;

  /// A list of the globs used to determine which files should be analyzed. The
  /// list is lazily created and should be accessed using [analyzedFilesGlobs].
  List<Glob> _analyzedFilesGlobs = null;

  AbstractAnalysisServer(this.options, this.diagnosticServer,
      ResourceProvider baseResourceProvider)
      : resourceProvider = OverlayResourceProvider(baseResourceProvider) {
    performance = performanceDuringStartup;
  }

  /// Return a list of the globs used to determine which files should be
  /// analyzed.
  List<Glob> get analyzedFilesGlobs {
    if (_analyzedFilesGlobs == null) {
      _analyzedFilesGlobs = <Glob>[];
      for (String pattern in analyzableFilePatterns) {
        try {
          _analyzedFilesGlobs
              .add(new Glob(resourceProvider.pathContext.separator, pattern));
        } catch (exception, stackTrace) {
          AnalysisEngine.instance.instrumentationService.logException(
              new CaughtException.withMessage(
                  'Invalid glob pattern: "$pattern"', exception, stackTrace));
        }
      }
    }
    return _analyzedFilesGlobs;
  }

  /// The list of current analysis sessions in all contexts.
  List<AnalysisSession> get currentSessions {
    return driverMap.values.map((driver) => driver.currentSession).toList();
  }

  /// A table mapping [Folder]s to the [AnalysisDriver]s associated with them.
  Map<Folder, nd.AnalysisDriver> get driverMap => contextManager.driverMap;

  /// Return the total time the server's been alive.
  Duration get uptime {
    DateTime start = new DateTime.fromMillisecondsSinceEpoch(
        performanceDuringStartup.startTime);
    return new DateTime.now().difference(start);
  }

  void addContextsToDeclarationsTracker() {
    for (var driver in driverMap.values) {
      declarationsTracker?.addContext(driver.analysisContext);
      driver.resetUriResolution();
    }
  }

  /// If the state location can be accessed, return the file byte store,
  /// otherwise return the memory byte store.
  ByteStore createByteStore(ResourceProvider resourceProvider) {
    const int M = 1024 * 1024 /*1 MiB*/;
    const int G = 1024 * 1024 * 1024 /*1 GiB*/;

    const int memoryCacheSize = 128 * M;

    if (resourceProvider is OverlayResourceProvider) {
      OverlayResourceProvider overlay = resourceProvider;
      resourceProvider = overlay.baseProvider;
    }
    if (resourceProvider is PhysicalResourceProvider) {
      Folder stateLocation =
          resourceProvider.getStateLocation('.analysis-driver');
      if (stateLocation != null) {
        return new MemoryCachingByteStore(
            new EvictingFileByteStore(stateLocation.path, G), memoryCacheSize);
      }
    }

    return new MemoryCachingByteStore(new NullByteStore(), memoryCacheSize);
  }

  /// Return an analysis driver to which the file with the given [path] is
  /// added if one exists, otherwise a driver in which the file was analyzed if
  /// one exists, otherwise the first driver, otherwise `null`.
  nd.AnalysisDriver getAnalysisDriver(String path) {
    List<nd.AnalysisDriver> drivers = driverMap.values.toList();
    if (drivers.isNotEmpty) {
      // Sort the drivers so that more deeply nested contexts will be checked
      // before enclosing contexts.
      drivers.sort((first, second) =>
          second.contextRoot.root.length - first.contextRoot.root.length);
      nd.AnalysisDriver driver = drivers.firstWhere(
          (driver) => driver.contextRoot.containsFile(path),
          orElse: () => null);
      driver ??= drivers.firstWhere(
          (driver) => driver.knownFiles.contains(path),
          orElse: () => null);
      driver ??= drivers.first;
      return driver;
    }
    return null;
  }

  DartdocDirectiveInfo getDartdocDirectiveInfoFor(ResolvedUnitResult result) {
    return declarationsTracker
            ?.getContext(result.session.analysisContext)
            ?.dartdocDirectiveInfo ??
        new DartdocDirectiveInfo();
  }

  /// Return a [Future] that completes with the [Element] at the given
  /// [offset] of the given [file], or with `null` if there is no node at the
  /// [offset] or the node does not have an element.
  Future<Element> getElementAtOffset(String file, int offset) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (!priorityFiles.contains(file)) {
      var driver = getAnalysisDriver(file);
      if (driver == null) {
        return null;
      }

      var unitElementResult = await driver.getUnitElement(file);
      if (unitElementResult == null) {
        return null;
      }

      var element = findElementByNameOffset(unitElementResult.element, offset);
      if (element != null) {
        return element;
      }
    }

    AstNode node = await getNodeAtOffset(file, offset);
    return getElementOfNode(node);
  }

  /// Return the [Element] of the given [node], or `null` if [node] is `null` or
  /// does not have an element.
  Element getElementOfNode(AstNode node) {
    if (node == null) {
      return null;
    }
    if (node is SimpleIdentifier && node.parent is LibraryIdentifier) {
      node = node.parent;
    }
    if (node is LibraryIdentifier) {
      node = node.parent;
    }
    if (node is StringLiteral && node.parent is UriBasedDirective) {
      return null;
    }
    Element element = ElementLocator.locate(node);
    if (node is SimpleIdentifier && element is PrefixElement) {
      element = getImportElement(node);
    }
    return element;
  }

  /// Return a [Future] that completes with the resolved [AstNode] at the
  /// given [offset] of the given [file], or with `null` if there is no node as
  /// the [offset].
  Future<AstNode> getNodeAtOffset(String file, int offset) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    ResolvedUnitResult result = await getResolvedUnit(file);
    CompilationUnit unit = result?.unit;
    if (unit != null) {
      return new NodeLocator(offset).searchWithin(unit);
    }
    return null;
  }

  /// Return the unresolved unit for the file with the given [path].
  ParsedUnitResult getParsedUnit(String path) {
    if (!AnalysisEngine.isDartFileName(path)) {
      return null;
    }

    return getAnalysisDriver(path)?.currentSession?.getParsedUnit(path);
  }

  /// Return the resolved unit for the file with the given [path]. The file is
  /// analyzed in one of the analysis drivers to which the file was added,
  /// otherwise in the first driver, otherwise `null` is returned.
  Future<ResolvedUnitResult> getResolvedUnit(String path,
      {bool sendCachedToStream = false}) {
    if (!AnalysisEngine.isDartFileName(path)) {
      return null;
    }

    nd.AnalysisDriver driver = getAnalysisDriver(path);
    if (driver == null) {
      return new Future.value();
    }

    return driver
        .getResult(path, sendCachedToStream: sendCachedToStream)
        .catchError((e, st) {
      AnalysisEngine.instance.instrumentationService.logException(e, st);
      return null;
    });
  }

  /// Notify the declarations tracker that the file with the given [path] was
  /// changed - added, updated, or removed.  Schedule processing of the file.
  void notifyDeclarationsTracker(String path) {
    declarationsTracker?.changeFile(path);
    analysisDriverScheduler.notify(null);
  }

  void updateContextInDeclarationsTracker(nd.AnalysisDriver driver) {
    declarationsTracker?.discardContext(driver.analysisContext);
    declarationsTracker?.addContext(driver.analysisContext);
  }
}
