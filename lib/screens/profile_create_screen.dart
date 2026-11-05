import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/profile_service.dart';

class ProfileCreateScreen extends StatefulWidget {
  final Profile? editProfile;

  const ProfileCreateScreen({super.key, this.editProfile});

  @override
  State<ProfileCreateScreen> createState() => _ProfileCreateScreenState();
}

class _ProfileCreateScreenState extends State<ProfileCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  int _selectedColorIndex = 0;
  int _selectedIconCodePoint = Icons.person.codePoint;
  bool _isKids = false;
  bool _isLoading = false;

  bool get _isEditing => widget.editProfile != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _nameController.text = widget.editProfile!.name;
      _selectedColorIndex = widget.editProfile!.avatar.colorIndex;
      _selectedIconCodePoint = widget.editProfile!.avatar.iconCodePoint;
      _isKids = widget.editProfile!.isKids;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final avatar = ProfileAvatar(
        colorIndex: _selectedColorIndex,
        iconCodePoint: _selectedIconCodePoint,
      );

      if (_isEditing) {
        await ProfileService.updateProfile(
          id: widget.editProfile!.id,
          name: _nameController.text.trim(),
          avatar: avatar,
          isKids: _isKids,
        );
      } else {
        await ProfileService.createProfile(
          name: _nameController.text.trim(),
          avatar: avatar,
          isKids: _isKids,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save profile: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewColor = ProfileAvatar.palette[_selectedColorIndex];
    final previewIcon = ProfileAvatar.icons.firstWhere(
      (i) => i.codePoint == _selectedIconCodePoint,
      orElse: () => Icons.person,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          _isEditing ? 'Edit Profile' : 'Create Profile',
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 16),
              // Avatar preview
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: previewColor,
                  boxShadow: [
                    BoxShadow(
                      color: previewColor.withValues(alpha: 0.5),
                      blurRadius: 24,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(previewIcon, color: Colors.white, size: 52),
              ),
              const SizedBox(height: 28),

              // Name field
              TextFormField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Profile Name',
                  labelStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.red),
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  if (value.trim().length > 20) {
                    return 'Name must be 20 characters or less';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Kids profile toggle
              SwitchListTile(
                title: const Text(
                  'Kids Profile',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  'Only show age-appropriate content',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
                value: _isKids,
                onChanged: (value) => setState(() => _isKids = value),
                activeColor: Colors.green,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 24),

              // Color picker
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Color',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: ProfileAvatar.palette.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final color = ProfileAvatar.palette[index];
                    final isSelected = index == _selectedColorIndex;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedColorIndex = index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                          border: Border.all(
                            color: isSelected
                                ? Colors.white
                                : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: color.withValues(alpha: 0.6),
                                    blurRadius: 12,
                                  ),
                                ]
                              : null,
                        ),
                        child: isSelected
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 20,
                              )
                            : null,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),

              // Icon picker
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Icon',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: ProfileAvatar.icons.length,
                itemBuilder: (context, index) {
                  final icon = ProfileAvatar.icons[index];
                  final isSelected = icon.codePoint == _selectedIconCodePoint;
                  final currentColor =
                      ProfileAvatar.palette[_selectedColorIndex];
                  return GestureDetector(
                    onTap: () =>
                        setState(() => _selectedIconCodePoint = icon.codePoint),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: isSelected
                            ? currentColor.withValues(alpha: 0.3)
                            : Colors.white.withValues(alpha: 0.05),
                        border: Border.all(
                          color: isSelected ? currentColor : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        icon,
                        color: isSelected ? Colors.white : Colors.white54,
                        size: 26,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 32),

              // Save button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          _isEditing ? 'Save Changes' : 'Create Profile',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
