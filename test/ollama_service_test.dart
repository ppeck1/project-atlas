import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/ollama_service.dart';
import 'package:project_atlas/services/project_summary_models.dart';

void main() {
  group('OllamaService.summarizeProjectStructured', () {
    test(
      'retries once when validation fails and accepts corrected JSON',
      () async {
        final fake = await _FakeOllama.start([
          _FakeOllamaResponse.jsonContent('{"notes":["extracted content"]}'),
          _FakeOllamaResponse.jsonContent(_validSummaryJson),
        ]);
        addTearDown(fake.close);

        final result = await OllamaService(
          host: fake.host,
          model: 'test-model',
        ).summarizeProjectStructured(context: _context);

        expect(fake.requests, hasLength(2));
        expect(result.parsed, isNotNull);
        expect(result.validation.isValid, isTrue);
        expect(
          result.result.input,
          contains('previous response failed validation'),
        );
        expect(result.result.input, contains('missing_goal'));
      },
    );

    test('does not retry Ollama transport or model errors', () async {
      final fake = await _FakeOllama.start([
        _FakeOllamaResponse.error(500, 'model unavailable'),
      ]);
      addTearDown(fake.close);

      final result = await OllamaService(
        host: fake.host,
        model: 'missing-model',
      ).summarizeProjectStructured(context: _context);

      expect(fake.requests, hasLength(1));
      expect(result.parsed, isNull);
      expect(result.validation.isValid, isFalse);
      expect(result.validation.shouldRetry, isFalse);
      expect(result.validation.issues.single.code, 'model_error');
      expect(result.result.output, contains('Ollama returned HTTP 500'));
    });
  });

  group('OllamaResult', () {
    test('treats timeout and transport text as failed output', () {
      const timeout = OllamaResult(
        input: 'input',
        output: 'Ollama request failed: TimeoutException after 0:05:00.000000',
        kind: 'project_change_summary',
        title: 'Change Summary',
      );
      const http = OllamaResult(
        input: 'input',
        output: 'Ollama returned HTTP 500 for model "x"',
        kind: 'project_change_summary',
        title: 'Change Summary',
      );

      expect(timeout.isSuccess, isFalse);
      expect(http.isSuccess, isFalse);
    });
  });
}

const _context = ProjectSummaryContext(
  id: 'proj-1',
  title: 'Retry Project',
  status: 'active',
  workItems: [],
  people: [],
  risks: [],
  decisions: [],
  documents: [],
);

const _validSummaryJson = '''
{
  "goal": ["Ship a reliable project summary flow"],
  "currentState": "The summary flow is under validation.",
  "ownership": [
    {"person": "Unassigned", "work": [], "basis": "No people recorded"}
  ],
  "relevantDocuments": [],
  "blockersAndRisks": ["No risks recorded"],
  "nextActions": ["Record explicit work items in Atlas"],
  "confidence": "Based on supplied project context."
}
''';

class _FakeOllama {
  final HttpServer _server;
  final List<_FakeOllamaResponse> _responses;
  final List<Map<String, dynamic>> requests = [];
  var _nextResponse = 0;

  _FakeOllama._(this._server, this._responses);

  String get host => 'http://${_server.address.host}:${_server.port}';

  static Future<_FakeOllama> start(List<_FakeOllamaResponse> responses) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeOllama._(server, responses);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.trim().isNotEmpty) {
      requests.add(jsonDecode(body) as Map<String, dynamic>);
    }
    final response =
        _responses[_nextResponse < _responses.length
            ? _nextResponse++
            : _responses.length - 1];
    request.response.statusCode = response.statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(response.body);
    await request.response.close();
  }
}

class _FakeOllamaResponse {
  final int statusCode;
  final String body;

  const _FakeOllamaResponse._(this.statusCode, this.body);

  factory _FakeOllamaResponse.jsonContent(String content) =>
      _FakeOllamaResponse._(
        200,
        jsonEncode({
          'message': {'content': content},
        }),
      );

  factory _FakeOllamaResponse.error(int statusCode, String body) =>
      _FakeOllamaResponse._(statusCode, body);
}
