import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../models/app_state_scope.dart';

class ContactOwnerField extends StatefulWidget {
  final TextEditingController controller;
  final String label;

  const ContactOwnerField({
    super.key,
    required this.controller,
    this.label = 'Owner',
  });

  @override
  State<ContactOwnerField> createState() => _ContactOwnerFieldState();
}

class _ContactOwnerFieldState extends State<ContactOwnerField> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = _clean(widget.controller.text);
  }

  String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<Contact>>(
      stream: state.watchContacts(),
      builder: (context, snap) {
        final contacts = snap.data ?? const <Contact>[];
        final names = <String>{for (final c in contacts) c.name.trim()};
        final manual = _clean(widget.controller.text);
        final selected = _clean(_selected) ?? manual;
        final dropdownValue = selected != null && names.contains(selected)
            ? selected
            : selected != null
            ? '__manual__$selected'
            : null;
        final items = <DropdownMenuItem<String>>[
          const DropdownMenuItem(value: null, child: Text('No owner')),
          ...contacts.map(
            (c) => DropdownMenuItem(value: c.name, child: Text(c.name)),
          ),
          if (selected != null && !names.contains(selected))
            DropdownMenuItem(
              value: '__manual__$selected',
              child: Text('$selected (manual)'),
            ),
          const DropdownMenuItem(
            value: '__create__',
            child: Text('Create contact...'),
          ),
        ];

        return DropdownButtonFormField<String>(
          value: dropdownValue,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
          ),
          items: _dedupe(items),
          onChanged: (value) async {
            if (value == '__create__') {
              final created = await showContactEditor(context);
              if (created != null) {
                widget.controller.text = created.name;
                setState(() => _selected = created.name);
              }
              return;
            }
            final owner = value?.startsWith('__manual__') == true
                ? value!.replaceFirst('__manual__', '')
                : value;
            widget.controller.text = owner ?? '';
            setState(() => _selected = owner);
          },
        );
      },
    );
  }

  List<DropdownMenuItem<String>> _dedupe(List<DropdownMenuItem<String>> items) {
    final seen = <String?>{};
    return [
      for (final item in items)
        if (seen.add(item.value)) item,
    ];
  }
}

Future<Contact?> showContactEditor(
  BuildContext context, {
  Contact? contact,
}) async {
  final state = AppStateScope.of(context);
  final name = TextEditingController(text: contact?.name ?? '');
  final title = TextEditingController(text: contact?.title ?? '');
  final phone = TextEditingController(text: contact?.phone ?? '');
  final altPhone = TextEditingController(text: contact?.alternatePhone ?? '');
  final email = TextEditingController(text: contact?.email ?? '');
  final website = TextEditingController(text: contact?.website ?? '');
  final business = TextEditingController(text: contact?.businessName ?? '');
  final notes = TextEditingController(text: contact?.notes ?? '');
  final photo = TextEditingController(text: contact?.photoPath ?? '');
  var saving = false;
  String? error;

  final savedId = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(contact == null ? 'Create contact' : 'Edit contact'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(name, 'Name *'),
                _field(title, 'Title'),
                Row(
                  children: [
                    Expanded(child: _field(phone, 'Phone')),
                    const SizedBox(width: 8),
                    Expanded(child: _field(altPhone, 'Alternate phone')),
                  ],
                ),
                _field(email, 'Email'),
                _field(website, 'Website'),
                _field(business, 'Business name'),
                _field(photo, 'Photo path'),
                _field(notes, 'Notes', maxLines: 4),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    final trimmed = name.text.trim();
                    if (trimmed.isEmpty) {
                      setLocal(() => error = 'Name is required.');
                      return;
                    }
                    setLocal(() {
                      saving = true;
                      error = null;
                    });
                    try {
                      final id = await state.saveContact(
                        id: contact?.id,
                        name: trimmed,
                        title: title.text,
                        phone: phone.text,
                        alternatePhone: altPhone.text,
                        email: email.text,
                        website: website.text,
                        businessName: business.text,
                        notes: notes.text,
                        photoPath: photo.text,
                      );
                      if (ctx.mounted) Navigator.pop(ctx, id);
                    } catch (e) {
                      setLocal(() {
                        saving = false;
                        error = e.toString();
                      });
                    }
                  },
            child: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(contact == null ? 'Create' : 'Save'),
          ),
        ],
      ),
    ),
  );

  for (final c in [
    name,
    title,
    phone,
    altPhone,
    email,
    website,
    business,
    notes,
    photo,
  ]) {
    c.dispose();
  }
  if (savedId == null) return null;
  return state.db.getContact(savedId);
}

Widget _field(TextEditingController ctrl, String label, {int maxLines = 1}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: ctrl,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
