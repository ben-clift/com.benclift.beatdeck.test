import 'package:flutter/material.dart';
import 'package:sidedeck/state/admin.dart';

/// Asks for the admin code, or turns admin off when it is already on.
Future<void> showAdminDialog(BuildContext context) async {
  if (Admin.on.value) {
    await Admin.lock();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Admin is off.')));
    }
    return;
  }
  final c = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Admin code'),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(hintText: 'Code'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
  if (code == null || !context.mounted) return;
  final ok = await Admin.unlock(code);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(ok ? 'Admin is on.' : 'That code is not right.')),
  );
}
