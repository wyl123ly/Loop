import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

class AgentPlanCard extends StatelessWidget {
  const AgentPlanCard({super.key, required this.plan});

  final List<PlanItem> plan;

  @override
  Widget build(BuildContext context) {
    if (plan.isEmpty) return const SizedBox.shrink();
    final done = plan.where((item) => item.status == 'done').length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: panelDecoration(radius: LoopRadius.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 15, color: pal.accent),
              const SizedBox(width: 6),
              Text('执行计划',
                  style: TextStyle(fontSize: LoopType.secondary, fontWeight: FontWeight.w600, color: pal.ink)),
              const Spacer(),
              Text('$done/${plan.length}',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
            ],
          ),
          const SizedBox(height: 8),
          for (final item in plan)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _statusIcon(item.status),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      item.title,
                      style: TextStyle(
                        fontSize: LoopType.secondary,
                        height: 1.45,
                        color: item.status == 'skipped' ? pal.muted : pal.ink,
                        decoration: item.status == 'done' ? TextDecoration.lineThrough : null,
                        decorationColor: pal.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'done':
        return Icon(Icons.check_circle_rounded, size: 14, color: pal.success);
      case 'in_progress':
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.8, color: pal.accent),
        );
      case 'failed':
        return Icon(Icons.error_outline_rounded, size: 14, color: pal.dangerInk);
      case 'skipped':
        return Icon(Icons.remove_circle_outline_rounded, size: 14, color: pal.muted);
      default:
        return Icon(Icons.circle_outlined, size: 14, color: pal.muted);
    }
  }
}
