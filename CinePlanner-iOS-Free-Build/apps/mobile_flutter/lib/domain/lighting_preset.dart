import 'lighting_plan.dart';

class LightingPreset {
  final String id, name, sourceShotId, createdBy;
  final int sourceRevision;
  final DateTime createdAt;
  final LightingPlan plan;
  LightingPreset({
    required this.id,
    required this.name,
    required this.sourceShotId,
    required this.sourceRevision,
    required this.createdAt,
    required this.createdBy,
    required this.plan,
  }) {
    if (id.isEmpty ||
        name.trim().isEmpty ||
        name.length > 80 ||
        sourceShotId.isEmpty ||
        sourceRevision < 1 ||
        createdBy.isEmpty) {
      throw const FormatException('Invalid lighting preset');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'source_shot_id': sourceShotId,
    'source_revision': sourceRevision,
    'created_at': createdAt.toUtc().toIso8601String(),
    'created_by': createdBy,
    'plan': plan.toJson(),
  };
  factory LightingPreset.fromJson(Map<String, dynamic> json) => LightingPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    sourceShotId: json['source_shot_id'] as String,
    sourceRevision: json['source_revision'] as int,
    createdAt: DateTime.parse(json['created_at'] as String),
    createdBy: json['created_by'] as String,
    plan: LightingPlan.fromJson(Map<String, dynamic>.from(json['plan'] as Map)),
  );
}
