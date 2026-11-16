import 'dart:convert';

enum EntityKind { organization, project, shootDay, scene, shot, take }

extension EntityKindLabel on EntityKind {
  String get label => this == EntityKind.shootDay ? 'shoot day' : name;
}

Object? _freezeJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freezeJson(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeJson));
  return value;
}

/// Stable IDs are independent of labels and display numbering.
class ProductionRecord {
  final String id;
  final EntityKind kind;
  final String organizationId;
  final String? projectId;
  final String? parentId;
  final String title;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final String updatedBy;
  final DateTime? deletedAt;
  final Map<String, Object?> data;

  ProductionRecord({
    required this.id,
    required this.kind,
    required this.organizationId,
    this.projectId,
    this.parentId,
    required this.title,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    required this.updatedBy,
    this.deletedAt,
    Map<String, Object?> data = const {},
  }) : data =
           _freezeJson(jsonDecode(jsonEncode(data))) as Map<String, Object?> {
    if (id.isEmpty ||
        organizationId.isEmpty ||
        title.trim().isEmpty ||
        revision < 1) {
      throw ArgumentError('Invalid record identity, title or revision');
    }
    if (kind == EntityKind.organization &&
        (id != organizationId || parentId != null || projectId != null)) {
      throw ArgumentError('Organization must be its own root');
    }
    if (kind != EntityKind.organization && parentId == null) {
      throw ArgumentError('Non-root record requires parent');
    }
    if (kind != EntityKind.organization && projectId == null) {
      throw ArgumentError('Project-owned record requires project ID');
    }
    if (kind == EntityKind.project && projectId != id) {
      throw ArgumentError('Project must reference its own ID');
    }
  }

  ProductionRecord edit({
    String? title,
    Map<String, Object?>? data,
    required String actor,
    required DateTime at,
    bool delete = false,
  }) => ProductionRecord(
    id: id,
    kind: kind,
    organizationId: organizationId,
    projectId: projectId,
    parentId: parentId,
    title: title ?? this.title,
    revision: revision + 1,
    createdAt: createdAt,
    updatedAt: at.toUtc(),
    createdBy: createdBy,
    updatedBy: actor,
    deletedAt: delete ? at.toUtc() : deletedAt,
    data: data ?? this.data,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'kind': kind.name,
    'organization_id': organizationId,
    'project_id': projectId,
    'parent_id': parentId,
    'title': title,
    'revision': revision,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'created_by': createdBy,
    'updated_by': updatedBy,
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'data': data,
  };

  factory ProductionRecord.fromJson(Map<String, dynamic> j) {
    if (j['schema_version'] != 1) throw FormatException('Unsupported schema');
    return ProductionRecord(
      id: j['id'] as String,
      kind: EntityKind.values.byName(j['kind'] as String),
      organizationId: j['organization_id'] as String,
      projectId: j['project_id'] as String?,
      parentId: j['parent_id'] as String?,
      title: j['title'] as String,
      revision: j['revision'] as int,
      createdAt: DateTime.parse(j['created_at'] as String),
      updatedAt: DateTime.parse(j['updated_at'] as String),
      createdBy: j['created_by'] as String,
      updatedBy: j['updated_by'] as String,
      deletedAt: j['deleted_at'] == null
          ? null
          : DateTime.parse(j['deleted_at'] as String),
      data: Map<String, Object?>.from(j['data'] as Map),
    );
  }
}
