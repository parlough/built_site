// Copyright (c) 2017 Luis Vargas, dart-league team.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:path/path.dart' show url;
import 'package:sass/sass.dart';

/// A `Builder` to compile `.css` files from `.scss` or `.sass` source using
/// the Dart implementation of Sass.
class SassBuilder extends Builder {
  final OutputStyle _outputStyle;
  final bool _writeSourceMaps;

  SassBuilder(
      {OutputStyle output = OutputStyle.expanded, bool writeSourceMaps = true})
      : _outputStyle = output,
        _writeSourceMaps = writeSourceMaps;

  @override
  Map<String, List<String>> get buildExtensions {
    final outputs = ['.css', if (_writeSourceMaps) '.css.map'];

    return {
      '.sass': outputs,
      '.scss': outputs,
    };
  }

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = buildStep.inputId;
    final basename = url.basename(input.path);

    if (basename.startsWith('_')) {
      // Don't compile files starting with an underscore, they're meant to be
      // imported.
      return;
    }

    final importer = BuildImporter.forStep(buildStep);
    final mainResult = await importer._loadAsset(input);
    AssetId? sourceMap;

    final result = await compileStringToResultAsync(
      mainResult.contents,
      syntax: mainResult.syntax,
      importers: [importer],
      style: _outputStyle,
      url: mainResult.sourceMapUrl,
      quietDeps: true,
      sourceMap: _writeSourceMaps,
    );
    var css = result.css;

    if (result.sourceMap != null) {
      final id = sourceMap = input.changeExtension('.css.map');
      final map = result.sourceMap!.toJson();

      // We need to replace source map uris to reflect the paths generated by
      // Dart's build system.
      final sources = map['sources'] as List<String>;
      for (var i = 0; i < sources.length; i++) {
        final uri = Uri.tryParse(sources[i]);
        if (uri == null) continue;

        final asset = AssetId.resolve(uri, from: input);
        if (url.isWithin('lib', asset.path)) {
          // The source is in lib/, which means that webdev and friends will
          // copy it to /packages/<package>/<source_in_lib>
          sources[i] = url.join(
              'packages', asset.package, url.relative(asset.path, from: 'lib'));
        } else if (asset.package == input.package) {
          // Assets from the root package are included if they're in web/, so
          // we might have a chance to still recover the source.
          if (url.isWithin('web', asset.path)) {
            sources[i] = url.relative(asset.path, from: 'web');
          }
        }
      }

      await buildStep.writeAsString(id, json.encode(map));

      // Add the source mapping information to the generated css

      final import = url.relative(sourceMap.path, from: input.path);
      css += '\n\n/*# sourceMappingURL=$import */"';
    }

    // Write the builder output.
    final outputId = input.changeExtension('.css');
    await buildStep.writeAsString(outputId, css);
  }
}

/// A [AsyncImporter] for use during a [BuildStep] that supports Dart package
///  imports of Sass files.
///
/// All methods are heavily inspired by functions from for import priorities:
/// https://github.com/sass/dart-sass/blob/f8b2c9111c1d5a3c07c9c8c0828b92bd87c548c9/lib/src/importer/utils.dart
class BuildImporter extends AsyncImporter {
  final AssetReader _reader;
  final AssetId _inputId;

  BuildImporter(this._reader, this._inputId);

  BuildImporter.forStep(BuildStep step)
      : _reader = step,
        _inputId = step.inputId;

  @override
  Future<Uri?> canonicalize(Uri url) async =>
      (await _resolveImport(url.toString()))?.uri;

  @override
  Future<ImporterResult> load(Uri url) {
    final id = AssetId.resolve(url, from: _inputId);
    return _loadAsset(id);
  }

  Future<ImporterResult> _loadAsset(AssetId id) async {
    return ImporterResult(
      await _reader.readAsString(id),
      sourceMapUrl: id.uri,
      syntax: Syntax.forPath(id.path),
    );
  }

  /// Resolves [import] using the same logic as the filesystem importer.
  ///
  /// This tries to fill in extensions and partial prefixes and check if a
  /// directory default. If no file can be found, it returns `null`.
  Future<AssetId?> _resolveImport(String import) async {
    final extension = url.extension(import);
    if (extension == '.sass' || extension == '.scss') {
      return _exactlyOne(await _tryImport(import));
    }

    return _exactlyOne(await _tryImportWithExtensions(import)) ??
        await _tryImportAsDirectory(import);
  }

  /// Like [_tryImport], but checks both `.sass` and `.scss` extensions.
  Future<List<AssetId>> _tryImportWithExtensions(String import) async =>
      await _tryImport(import + '.sass') + await _tryImport(import + '.scss');

  /// Returns the [AssetId] for [import] and/or the partial with the same name,
  /// if either or both exists.
  ///
  /// If neither exists, returns an empty list.
  Future<List<AssetId>> _tryImport(String import) async {
    final imports = <AssetId>[];
    final partialId = AssetId.resolve(
        Uri.parse(url.join(url.dirname(import), '_${url.basename(import)}')),
        from: _inputId);
    if (await _reader.canRead(partialId)) imports.add(partialId);
    final importId = AssetId.resolve(Uri.parse(import), from: _inputId);
    if (await _reader.canRead(importId)) imports.add(importId);
    return imports;
  }

  /// Returns the resolved index file for [import] if [import] is a directory
  /// and the index file exists.
  ///
  /// Otherwise, returns `null`.
  Future<AssetId?> _tryImportAsDirectory(String import) async =>
      _exactlyOne(await _tryImportWithExtensions(url.join(import, 'index')));

  /// If [imports] contains exactly one import [AssetId], returns that import.
  ///
  /// If it contains no assets, returns `null`. If it contains more than one,
  /// throws an exception.
  AssetId? _exactlyOne(List<AssetId> imports) {
    if (imports.isEmpty) return null;
    if (imports.length == 1) return imports.first;

    throw FormatException('It is not clear which file to import. Found:\n' +
        imports.map((import) => '  ${url.prettyUri(import.uri)}').join('\n'));
  }
}
