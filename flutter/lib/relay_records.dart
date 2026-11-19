typedef Json = Map<String, dynamic>;

class WorkspaceApp {
  WorkspaceApp.fromJson(Json json)
    : id = json['id'],
      name = json['name'],
      description = json['description'],
      protocolVersion = json['protocolVersion'],
      canSearch =
          json['capabilities']?['search'] == true ||
          json['protocolVersion'] != 2;
  final String id, name;
  final String? description;
  final int? protocolVersion;
  final bool canSearch;
  static const browserId = 'browser';
  bool get isBrowser => id == browserId;
  bool get opensInLibrary => !isBrowser && protocolVersion != 2;
}

class Conversation {
  Conversation.fromJson(Json json)
    : id = json['id'],
      title = json['title'],
      botId = json['botId'],
      reasoningEffort = json['reasoningEffort'],
      createdAt = json['createdAt'],
      trashedAt = json['trashedAt'];
  final String id;
  final String? title, botId, reasoningEffort, createdAt, trashedAt;
}

class ChatMessage {
  ChatMessage.fromJson(Json json)
    : id = json['id'],
      role = json['role'],
      text = json['text'] ?? '',
      createdAt = json['createdAt'],
      hasCapture = json['hasCapture'] == true,
      context = json['context'];
  final String role, text;
  final bool hasCapture;
  final String? id, createdAt;
  final Json? context;
}

class ConversationRun {
  ConversationRun.fromJson(Json json)
    : id = json['id'],
      status = json['status'],
      startedAt = json['startedAt'],
      error = json['error'];
  final String id, status;
  final String? startedAt, error;
}

class ToolRecord {
  ToolRecord.fromJson(Json json)
    : runId = json['runId'],
      name = json['name'],
      status = json['status'],
      input = json['input'],
      output = json['output'],
      progress = (json['progress'] as List?)?.cast<Json>();
  final String runId, name;
  final String? status;
  final Object? input, output;
  final List<Json>? progress;
}

class ViewCommand {
  ViewCommand.fromJson(this.json)
    : id = json['id'],
      runId = json['runId'],
      deviceId = json['deviceId'],
      tabId = json['tabId'],
      kind = json['kind'],
      status = json['status'],
      expectedViewToken = json['expectedViewToken'],
      appId = json['appId'],
      error = json['error'],
      intent = json['intent'],
      source = json['source'],
      sectionId = json['sectionId'],
      highlightIds = (json['highlightIds'] as List?)?.cast<String>(),
      viewState = json['viewState'];
  // The page receives the original command, including the app's intent and state.
  final Json json;
  final String id, runId, deviceId, tabId, kind, status;
  final String? expectedViewToken, appId, error, sectionId;
  final Json? intent, source, viewState;
  final List<String>? highlightIds;
}

class ConversationSnapshot {
  ConversationSnapshot.fromJson(Json json)
    : conversation = json['conversation'] == null
          ? null
          : Conversation.fromJson(json['conversation']),
      messages = (json['messages'] as List)
          .cast<Json>()
          .map(ChatMessage.fromJson)
          .toList(),
      runs = ((json['runs'] as List?) ?? [])
          .cast<Json>()
          .map(ConversationRun.fromJson)
          .toList(),
      tools = ((json['tools'] as List?) ?? [])
          .cast<Json>()
          .map(ToolRecord.fromJson)
          .toList(),
      commands = ((json['commands'] as List?) ?? [])
          .cast<Json>()
          .map(ViewCommand.fromJson)
          .toList(),
      forwards = ((json['forwards'] as List?) ?? []).cast<Json>(),
      checkpoint = json['checkpoint'];
  final Conversation? conversation;
  final List<ChatMessage> messages;
  final List<ConversationRun> runs;
  final List<ToolRecord> tools;
  final List<ViewCommand> commands;
  final List<Json> forwards;
  final Json? checkpoint;
}
