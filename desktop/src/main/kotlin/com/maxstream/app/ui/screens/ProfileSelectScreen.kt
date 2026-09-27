package com.maxstream.app.ui.screens

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import coil3.compose.AsyncImage
import com.maxstream.app.data.cloud.AppSession
import com.maxstream.app.data.cloud.CloudSync
import com.maxstream.app.data.cloud.ProfileStore
import com.maxstream.app.data.cloud.UserProfile
import com.maxstream.app.data.repository.TmdbRepository
import com.maxstream.app.resources.Res
import com.maxstream.app.resources.maxstream_logo
import org.jetbrains.compose.resources.painterResource
import com.maxstream.app.ui.components.appClickable
import com.maxstream.app.ui.components.appFocusRing
import com.maxstream.app.ui.theme.AppColors
import com.maxstream.app.ui.theme.AppSpacing
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** MaxStream avatar palette — same order as the mobile ProfileAvatar.palette. */
private val AvatarPalette = listOf(
    Color(0xFFE50914), Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFEC4899),
    Color(0xFFF59E0B), Color(0xFF10B981), Color(0xFF06B6D4), Color(0xFF3B82F6),
    Color(0xFFEF4444), Color(0xFF14B8A6), Color(0xFFF97316), Color(0xFFA855F7),
)

private val AvatarIcons = listOf(
    Icons.Default.Person, Icons.Default.Movie, Icons.Default.Star, Icons.Default.Add,
)

private const val HeroCycleMs = 5_000L

private data class HeroSlide(
    val url: String,
    val title: String,
    val subtitle: String,
)

/**
 * Who's watching? — mirrors the mobile/TV profile gate: backdrop carousel,
 * centered title + profile grid, and add-profile tile. Selecting a profile
 * activates it, syncs cloud data for that profile, and continues into the shell.
 * Long-press-free edit: hover a tile to reveal a pencil; the add tile opens a
 * create dialog (name, kids, color) like mobile's profile_create_screen.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun ProfileSelectScreen(onSelected: () -> Unit) {
    var loading by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    var heroes by remember { mutableStateOf<List<HeroSlide>>(emptyList()) }
    var heroIndex by remember { mutableIntStateOf(0) }
    var editing by remember { mutableStateOf<UserProfile?>(null) }
    var creating by remember { mutableStateOf(false) }
    var manageError by remember { mutableStateOf<String?>(null) }
    var heroHovered by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        runCatching { ProfileStore.refresh() }
        loading = false
    }

    LaunchedEffect(Unit) {
        heroes = runCatching {
            val sections = TmdbRepository.homeSections()
            val picked = (sections.firstOrNull { it.title.contains("Trending movies", true) }?.items.orEmpty() +
                sections.firstOrNull { it.title.contains("Trending series", true) }?.items.orEmpty())
                .filter { it.backdropUrl != null }
                .shuffled()
                .take(12)
            picked.map { item ->
                HeroSlide(
                    url = item.backdropUrl.orEmpty(),
                    title = item.title,
                    subtitle = listOf(item.typeLabel, item.displayYear)
                        .filter { it.isNotBlank() }
                        .joinToString("  •  "),
                )
            }.filter { it.url.isNotBlank() }
        }.getOrDefault(emptyList())
    }

    LaunchedEffect(heroes.size, heroHovered) {
        if (heroes.size < 2) return@LaunchedEffect
        while (isActive && !heroHovered) {
            delay(HeroCycleMs)
            if (!heroHovered) heroIndex = (heroIndex + 1) % heroes.size
        }
    }

    val currentHero = heroes.getOrNull(heroIndex)

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onPointerEvent(PointerEventType.Enter) { heroHovered = true }
            .onPointerEvent(PointerEventType.Exit) { heroHovered = false },
    ) {
        if (currentHero != null) {
            Crossfade(
                targetState = currentHero,
                animationSpec = tween(800),
                label = "profileHero",
                modifier = Modifier.fillMaxSize(),
            ) { slide ->
                AsyncImage(
                    model = slide.url,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    listOf(
                        Color.Black.copy(alpha = 0.72f),
                        Color.Black.copy(alpha = 0.88f),
                        Color.Black,
                    ),
                ),
            ),
        )

        Column(
            Modifier.fillMaxSize().padding(horizontal = 48.dp, vertical = 36.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Image(
                painter = painterResource(Res.drawable.maxstream_logo),
                contentDescription = "MaxStream",
                modifier = Modifier.height(64.dp),
            )
            Spacer(Modifier.height(18.dp))
            Text(
                "Who's watching?",
                color = Color.White,
                fontSize = 30.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Choose a profile to start streaming",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.weight(1f))

            if (loading) {
                CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
            } else {
                val profiles = ProfileStore.profiles
                val tiles = buildList {
                    profiles.forEach { add(Tile.ProfileTile(it)) }
                    if (profiles.size < ProfileStore.MAX_PROFILES) add(Tile.Add)
                }
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    tiles.chunked(3).forEach { row ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally),
                            modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp),
                        ) {
                            row.forEach { tile ->
                                when (tile) {
                                    is Tile.ProfileTile -> ProfileTile(
                                        profile = tile.profile,
                                        onClick = {
                                            ProfileStore.setActive(tile.profile.id)
                                            scope.launch {
                                                if (AppSession.isSignedIn) {
                                                    CloudSync.syncWatchHistory()
                                                    CloudSync.bump()
                                                }
                                                onSelected()
                                            }
                                        },
                                        onEdit = { editing = tile.profile },
                                    )
                                    Tile.Add -> AddProfileTile(
                                        onClick = { creating = true },
                                    )
                                }
                            }
                        }
                    }
                }

                Spacer(Modifier.weight(1f))

                val slide = currentHero
                if (slide != null) {
                    Text(
                        slide.title,
                        color = Color.White,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(0.7f),
                    )
                    if (slide.subtitle.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            slide.subtitle,
                            color = Color.White.copy(alpha = 0.65f),
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Spacer(Modifier.height(14.dp))
                }
                Text(
                    "Click a profile to start watching",
                    color = Color.White.copy(alpha = 0.45f),
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }

        if (creating) {
            ProfileEditDialog(
                profile = null,
                onDismiss = { creating = false },
                onError = { manageError = it },
                onSave = { name, kids, colorIndex ->
                    scope.launch {
                        // A thrown create used to kill the coroutine silently
                        // while the dialog closed — the profile never appeared.
                        try {
                            ProfileStore.create(
                                name = name,
                                colorIndex = colorIndex,
                                iconCodePoint = 0xe4ff,
                                isKids = kids,
                            )
                            creating = false
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (t: Throwable) {
                            manageError = t.message ?: "Could not create the profile."
                        }
                    }
                },
            )
        }

        editing?.let { target ->
            ProfileEditDialog(
                profile = target,
                onDismiss = { editing = null },
                onError = { manageError = it },
                onSave = { name, kids, colorIndex ->
                    scope.launch {
                        try {
                            ProfileStore.update(
                                id = target.id,
                                name = name,
                                colorIndex = colorIndex,
                                iconCodePoint = target.iconCodePoint,
                                isKids = kids,
                            )
                            editing = null
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (t: Throwable) {
                            manageError = t.message ?: "Could not update the profile."
                        }
                    }
                },
                onDelete = {
                    scope.launch {
                        try {
                            if (ProfileStore.profiles.size <= 1) {
                                manageError = "You need at least one profile."
                            } else {
                                ProfileStore.delete(target.id)
                                editing = null
                            }
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (t: Throwable) {
                            manageError = t.message ?: "Could not delete the profile."
                        }
                    }
                },
            )
        }

        manageError?.let { msg ->
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 24.dp)
                    .background(Color(0xCC1A1A1E), RoundedCornerShape(8.dp))
                    .semantics { liveRegion = LiveRegionMode.Polite }
                    .appClickable(cornerRadius = 8.dp) { manageError = null }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            ) {
                Text(msg, color = Color.White, fontSize = 13.sp)
            }
        }
    }
}

private sealed interface Tile {
    data class ProfileTile(val profile: UserProfile) : Tile
    data object Add : Tile
}

@Composable
private fun ProfileTile(profile: UserProfile, onClick: () -> Unit, onEdit: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    var focused by remember { mutableStateOf(false) }
    val color = AvatarPalette[profile.colorIndex.mod(AvatarPalette.size)]
    val icon = AvatarIcons[0]

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(130.dp)
            .scale(if (hovered) 1.05f else 1f)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            // Pencil edit affordance is hover-only by default — keyboard users
            // could never reach it; show it on focus too, and ring the tile.
            .onFocusChanged { focused = it.isFocused }
            .appFocusRing(cornerRadius = 12.dp, ringColor = Color.White),
    ) {
        Box(
            Modifier
                .size(96.dp)
                .clip(CircleShape)
                .background(color)
                .border(
                    3.dp,
                    if (hovered || focused) Color.White else color.copy(alpha = 0.9f),
                    CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = profile.name, tint = Color.White, modifier = Modifier.size(42.dp))
            if (hovered || focused) {
                Box(
                    Modifier
                        .align(Alignment.BottomEnd)
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.75f))
                        .clickable(onClick = onEdit),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("✎", color = Color.White, fontSize = 14.sp)
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(
            profile.name,
            color = Color.White,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
        if (profile.isKids) {
            Spacer(Modifier.height(4.dp))
            Text(
                "KIDS",
                color = Color(0xFF10B981),
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .background(Color(0xFF10B981).copy(alpha = 0.18f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
    }
}

@Composable
private fun AddProfileTile(onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(130.dp)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .appFocusRing(cornerRadius = 12.dp, ringColor = Color.White),
    ) {
        Box(
            Modifier
                .size(96.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.06f))
                .border(2.dp, Color.White.copy(alpha = if (hovered) 0.55f else 0.25f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Add,
                contentDescription = "Add profile",
                tint = Color.White.copy(alpha = 0.55f),
                modifier = Modifier.size(40.dp),
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(
            "Add Profile",
            color = Color.White.copy(alpha = 0.5f),
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * Create/edit profile dialog: name, kids toggle, avatar color — same fields as
 * mobile's profile_create_screen / profile management bottom sheet.
 */
@Composable
private fun ProfileEditDialog(
    profile: UserProfile?,
    onDismiss: () -> Unit,
    onSave: (name: String, isKids: Boolean, colorIndex: Int) -> Unit,
    onError: (String) -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    var name by remember(profile?.id) { mutableStateOf(profile?.name ?: "") }
    var kids by remember(profile?.id) { mutableStateOf(profile?.isKids ?: false) }
    var colorIndex by remember(profile?.id) { mutableStateOf(profile?.colorIndex ?: 0) }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .width(380.dp)
                .heightIn(max = 640.dp)
                .verticalScroll(rememberScrollState())
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF1A1A1E))
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                if (profile == null) "Add Profile" else "Edit Profile",
                color = Color.White,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(18.dp))

            Box(
                Modifier
                    .size(84.dp)
                    .clip(CircleShape)
                    .background(AvatarPalette[colorIndex.mod(AvatarPalette.size)]),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    AvatarIcons[0],
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(38.dp),
                )
            }
            Spacer(Modifier.height(16.dp))

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Profile name", color = Color.White.copy(alpha = 0.8f)) },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = Color.White),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = MaterialTheme.colorScheme.primary,
                    unfocusedBorderColor = Color.White.copy(alpha = 0.35f),
                    focusedLabelColor = MaterialTheme.colorScheme.primary,
                    unfocusedLabelColor = Color.White.copy(alpha = 0.7f),
                    cursorColor = Color.White,
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(14.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Kids profile", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                Switch(checked = kids, onCheckedChange = { kids = it })
            }
            Spacer(Modifier.height(14.dp))

            Text("Avatar color", color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
            // 12 swatches in one row overflowed the 380dp dialog — wrap them.
            AvatarPalette.chunked(6).forEachIndexed { rowIndex, rowColors ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(AppSpacing.sm),
                    modifier = Modifier.padding(bottom = AppSpacing.sm),
                ) {
                    rowColors.forEachIndexed { colOffset, color ->
                        val index = rowIndex * 6 + colOffset
                        Box(
                            Modifier
                                .size(28.dp)
                                .clip(CircleShape)
                                .background(color)
                                .border(
                                    if (index == colorIndex) 3.dp else 1.dp,
                                    if (index == colorIndex) Color.White else Color.White.copy(alpha = 0.25f),
                                    CircleShape,
                                )
                                .appClickable(cornerRadius = 14.dp) { colorIndex = index },
                        )
                    }
                }
            }

            Spacer(Modifier.height(22.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
            ) {
                if (onDelete != null && profile != null) {
                    TextButton(onClick = onDelete) {
                        Text("Delete", color = AppColors.errorBright)
                    }
                }
                TextButton(onClick = onDismiss) {
                    Text("Cancel", color = Color.White.copy(alpha = 0.7f))
                }
                val canSave = name.isNotBlank()
                TextButton(
                    enabled = canSave,
                    onClick = {
                        if (name.isBlank()) {
                            onError("Enter a profile name.")
                        } else {
                            onSave(name.trim(), kids, colorIndex)
                        }
                    },
                ) {
                    Text(
                        "Save",
                        color = if (canSave) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.35f),
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
    }
}
