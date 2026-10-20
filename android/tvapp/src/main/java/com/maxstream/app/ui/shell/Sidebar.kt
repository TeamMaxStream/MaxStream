package com.maxstream.app.ui.shell

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MenuDefaults
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.RocketLaunch
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.R
import com.maxstream.app.data.local.ProfileData
import com.maxstream.app.data.local.ProfileScope
import com.maxstream.app.util.KidsTheme
import kotlinx.coroutines.launch

// ─────────────────────────────────────────────────────────────────────────────
// Data
// ─────────────────────────────────────────────────────────────────────────────

private data class NavEntry(val labelRes: Int, val iconRes: Int)

private val NAV_ENTRIES = listOf(
    NavEntry(R.string.home,      R.drawable.ic_home),
    NavEntry(R.string.search,    R.drawable.ic_search),
    NavEntry(R.string.genre,     R.drawable.ic_genre),
    NavEntry(R.string.series,    R.drawable.ic_series),
    NavEntry(R.string.library,   R.drawable.ic_library),
    NavEntry(R.string.more,      R.drawable.ic_more),
)

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Left sidebar navigation.
 *
 * Architecture notes (matches Dart TvSidebarNavigation):
 * - Width animation is driven by [isExpanded], which is true when any pill
 *   has focus.  [active] triggers programmatic focus on [selectedIndex] so
 *   the back-key / return-to-sidebar flow works identically to Dart.
 * - [focusRequesters] are created by MainActivity and shared so external code
 *   (back state machine) can programmatically focus a sidebar item.
 * - `canFocus` is NEVER set to false — items are always focusable; only the
 *   visual label is shown/hidden based on [_focusedIndex].
 * - A LazyColumn + [scrollToItem] keeps the selected pill visible when
 *   the list is longer than the screen.
 * - Key handler: ↑↓ move within sidebar, →/Enter selects and moves to content,
 *   ← is swallowed (no-op — already on the left edge), Back/Escape bubbles up
 *   to the shell's state machine.
 */
@Composable
fun Sidebar(
    selectedIndex: Int,
    focusRequesters: List<FocusRequester>,
    onItemSelected: (Int) -> Unit,
    onReturnToContent: () -> Unit,
    onFocusEntered: () -> Unit = {},
    onSwitchProfile: () -> Unit = {},
    active: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // ── Local focus state ──────────────────────────────────────────────────
    // -1 = no sidebar item focused (sidebar collapsed)
    var focusedIndex by remember { mutableIntStateOf(-1) }
    // Expand when a pill has focus OR the shell says we're sidebar-active
    // (the latter covers the brief window before focus lands after LEFT).
    //
    // NOTE: deliberately NOT wrapped in derivedStateOf. `active` is a plain
    // Boolean parameter (not a snapshot State), so `remember { derivedStateOf
    // { ... } }` would capture its FIRST value forever — the sidebar would
    // only ever expand once a pill already had focus, making LEFT→sidebar
    // appear to do nothing. A plain computed value re-evaluates on every
    // recomposition, which is exactly what we need here.
    val isExpanded = focusedIndex >= 0 || active
    val context = LocalContext.current

    val coroutineScope = rememberCoroutineScope()
    val listState = rememberLazyListState()

    // Focus requester for the profile switcher row (top of sidebar)
    val profileSwitcherFocusRequester = remember { FocusRequester() }

    // Load profiles for the profile switcher
    var profiles by remember { mutableStateOf(emptyList<ProfileData>()) }
    var activeProfileId by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        profiles = ProfileScope.getCachedProfiles(context)
        activeProfileId = ProfileScope.activeProfileId(context)
    }

    // Refresh active profile when sidebar expands (after returning from profile select)
    LaunchedEffect(isExpanded) {
        if (isExpanded) {
            activeProfileId = ProfileScope.activeProfileId(context)
            profiles = ProfileScope.getCachedProfiles(context)
        }
    }

    // When [active] changes from false → true, request focus on the
    // selected item until it actually gains focus. Mirrors Dart's
    // _requestFocusAfterFrames(node, retries) but is self-terminating: it
    // stops the moment a pill reports focus (focusedIndex >= 0).
    //
    // requestFocus() throws while the node is unattached and returns false if
    // the focus request is dropped, so a single attempt is unreliable — the
    // sidebar may be mid-expansion when the first request lands.
    LaunchedEffect(active, selectedIndex) {
        if (!active) return@LaunchedEffect
        var attempts = 0
        while (focusedIndex < 0 && attempts < 60) {
            kotlinx.coroutines.delay(50)
            attempts++
            try {
                // requestFocus() throws while the node is unattached (e.g. the
                // sidebar is mid-expansion) — keep retrying until the pill
                // actually reports focus via onFocusChanged → focusedIndex.
                focusRequesters.getOrNull(selectedIndex)?.requestFocus()
            } catch (e: Exception) {
                // not attached yet — retry
            }
        }
    }

    // Scroll to keep the selected pill visible when selectedIndex changes
    // (mirrors Dart's _scrollToSelected).
    LaunchedEffect(selectedIndex) {
        // LazyColumn items are laid out as: logo spacer (~72dp) + items
        // Each pill is ~52dp.  Scroll so the selected one is centered.
        val itemIndex = selectedIndex  // NAV index maps 1:1 to list items
        listState.animateScrollToItem(
            index = itemIndex,
            scrollOffset = -120,  // offset to center the item visually
        )
    }

    // ── Width animation ────────────────────────────────────────────────────
    val sidebarWidth by animateDpAsState(
        targetValue = if (isExpanded) 220.dp else 76.dp,
        animationSpec = tween(
            durationMillis = if (isExpanded) 200 else 150,
            easing = FastOutSlowInEasing,
        ),
        label = "sidebarWidth",
    )

    Box(
        modifier = modifier
            .width(sidebarWidth)
            .fillMaxHeight()
            .background(
                Brush.verticalGradient(
                    colors = listOf(KidsTheme.surface(context), KidsTheme.background(context))
                )
            )
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.09f),
                shape = RoundedCornerShape(0.dp),
            ),
        contentAlignment = Alignment.Center,
    ) {
        // Profile switcher at top (replaces logo when expanded)
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (isExpanded && profiles.isNotEmpty()) {
                var showDropdown by remember { mutableStateOf(false) }
                var isProfileFocused by remember { mutableStateOf(false) }
                val activeProfile = profiles.find { it.id == activeProfileId } ?: profiles.first()
                val activeColors = ProfileSidebarColors[activeProfile.colorIndex % ProfileSidebarColors.size]

                // Active profile row — opens dropdown
                Box {
                    Row(
                        modifier = Modifier
                            .width(196.dp)
                            .clip(RoundedCornerShape(20.dp))
                            .background(if (isProfileFocused) Color(0x38FFFFFF) else Color(0x20FFFFFF))
                            .border(
                                width = if (isProfileFocused) 2.dp else 0.dp,
                                color = if (isProfileFocused) Color.White else Color.Transparent,
                                shape = RoundedCornerShape(20.dp),
                            )
                            .focusRequester(profileSwitcherFocusRequester)
                            .onFocusChanged { state -> isProfileFocused = state.hasFocus }
                            .onKeyEvent { event ->
                                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                                when (event.key) {
                                    Key.DirectionDown -> {
                                        // Move focus to first sidebar pill
                                        runCatching { focusRequesters.firstOrNull()?.requestFocus() }
                                        true
                                    }
                                    Key.Enter, Key.DirectionCenter -> {
                                        showDropdown = true
                                        true
                                    }
                                    else -> false
                                }
                            }
                            .clickable { showDropdown = true }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(activeColors),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = ProfileSidebarIcon(activeProfile.iconCodePoint),
                                contentDescription = activeProfile.name,
                                tint = Color.White,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = activeProfile.name,
                            color = Color.White,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.W600,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Icon(
                            imageVector = Icons.Filled.ArrowDropDown,
                            contentDescription = "Switch profile",
                            tint = Color.White,
                            modifier = Modifier.size(18.dp),
                        )
                    }

                    // Dropdown popup with all profiles
                    DropdownMenu(
                        expanded = showDropdown,
                        onDismissRequest = { showDropdown = false },
                        modifier = Modifier
                            .width(200.dp)
                            .background(Color(0xFF1A1A1A)),
                    ) {
                        Text(
                            text = "Switch Profile",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.W500,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                        )
                        profiles.forEach { profile ->
                            val isActive = profile.id == activeProfileId
                            val pColor = ProfileSidebarColors[profile.colorIndex % ProfileSidebarColors.size]
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Box(
                                            modifier = Modifier
                                                .size(24.dp)
                                                .clip(RoundedCornerShape(12.dp))
                                                .background(pColor),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Icon(
                                                imageVector = ProfileSidebarIcon(profile.iconCodePoint),
                                                contentDescription = profile.name,
                                                tint = Color.White,
                                                modifier = Modifier.size(14.dp),
                                            )
                                        }
                                        Spacer(Modifier.width(10.dp))
                                        Text(
                                            text = profile.name,
                                            color = Color.White,
                                            fontSize = 13.sp,
                                            fontWeight = if (isActive) FontWeight.W600 else FontWeight.W400,
                                            modifier = Modifier.weight(1f),
                                        )
                                        if (isActive) {
                                            Text("✓", color = KidsTheme.navSelected(context), fontSize = 13.sp, fontWeight = FontWeight.Bold)
                                        }
                                    }
                                },
                                onClick = {
                                    showDropdown = false
                                    if (!isActive) {
                                        ProfileScope.setActiveProfileId(context, profile.id)
                                        activeProfileId = profile.id
                                        onSwitchProfile()
                                    }
                                },
                                colors = MenuDefaults.itemColors(
                                    textColor = Color.White,
                                ),
                            )
                        }
                    }
                }
            } else {
                // Collapsed: show logo
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.Black),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painter = painterResource(R.drawable.maxstream_logo),
                        contentDescription = "MaxStream",
                        tint = Color.Unspecified,
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
        }

        // Nav items in a LazyColumn for scroll support
        LazyColumn(
            state = listState,
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Spacer for the logo area at top
            item { Spacer(modifier = Modifier.height(72.dp)) }

            itemsIndexed(NAV_ENTRIES) { index, entry ->
                SidebarPillItem(
                    labelRes = entry.labelRes,
                    iconRes = entry.iconRes,
                    isSelected = index == selectedIndex,
                    isFocused = index == focusedIndex,
                    isExpanded = isExpanded,
                    focusRequester = focusRequesters[index],
                    onFocusChanged = { hasFocus ->
                        if (hasFocus) {
                            focusedIndex = index
                            onFocusEntered()
                            // Scroll to keep this item visible
                            coroutineScope.launch {
                                listState.animateScrollToItem(
                                    index = index + 1, // +1 for logo spacer
                                    scrollOffset = -120,
                                )
                            }
                        } else if (focusedIndex == index) {
                            focusedIndex = -1
                        }
                    },
                    onSelect = {
                        onItemSelected(index)
                        runCatching { onReturnToContent() }
                    },
                    onMoveUp = {
                        if (index > 0) runCatching { focusRequesters[index - 1].requestFocus() }
                        else runCatching { profileSwitcherFocusRequester.requestFocus() }
                    },
                    onMoveDown = {
                        if (index < NAV_ENTRIES.lastIndex) runCatching { focusRequesters[index + 1].requestFocus() }
                    },
                )
            }

            // Bottom spacer
            item { Spacer(modifier = Modifier.height(16.dp)) }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pill item
// ─────────────────────────────────────────────────────────────────────────────

@Composable
private fun SidebarPillItem(
    labelRes: Int,
    iconRes: Int,
    isSelected: Boolean,
    isFocused: Boolean,
    isExpanded: Boolean,
    focusRequester: FocusRequester,
    onFocusChanged: (Boolean) -> Unit,
    onSelect: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    val scale by animateFloatAsState(
        targetValue = if (isFocused) 1.05f else 1f,
        animationSpec = tween(200, easing = FastOutSlowInEasing),
        label = "pillScale",
    )

    // Animated pill width — mirrors Dart's AnimatedContainer (196 ↔ 56 dp,
    // 150ms easeOutCubic). Padding stays constant (12dp) so only the pill
    // width and the inner label slide.
    val pillWidth by animateDpAsState(
        targetValue = if (isExpanded) 196.dp else 56.dp,
        animationSpec = tween(150, easing = FastOutSlowInEasing),
        label = "pillWidth",
    )

    val bgColor = when {
        isSelected -> Color(0x38FFFFFF)
        isFocused  -> Color(0x1FFFFFFF)
        else       -> Color.Transparent
    }
    val borderColor = if (isFocused) Color.White else Color.Transparent
    val borderWidth = if (isFocused) 2.dp else 0.dp
    val iconTint = if (isSelected || isFocused) Color.White else Color(0xFF999999)
    val iconBg   = if (isSelected || isFocused) Color(0x38FFFFFF) else Color(0xFF222222)
    val labelColor = if (isSelected || isFocused) Color.White else Color(0xFF999999)

    Row(
        modifier = Modifier
            .scale(scale)
            .width(pillWidth)
            .clip(RoundedCornerShape(28.dp))
            .background(bgColor)
            .border(
                width = borderWidth,
                color = borderColor,
                shape = RoundedCornerShape(28.dp),
            )
            .focusRequester(focusRequester)
            .onFocusChanged { state -> onFocusChanged(state.hasFocus) }
            // D-pad: ↑↓ move within sidebar, →/Enter selects and moves to
            // content, ← is swallowed (already at the left edge).
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                when (event.key) {
                    Key.DirectionUp   -> { onMoveUp();  true }
                    Key.DirectionDown -> { onMoveDown(); true }
                    // Right arrow OR Enter/Select → select item and move to content
                    Key.DirectionRight,
                    Key.Enter,
                    Key.DirectionCenter -> { onSelect(); true }
                    // Left is already at the left edge — swallow so the system
                    // doesn't try to route to non-existent items further left.
                    Key.DirectionLeft -> true
                    // Back/Escape intentionally NOT handled here — let it bubble
                    // to the shell's onKeyEvent so the back state machine runs.
                    else -> false
                }
            }
            // clickable() provides its own focusable — no separate .focusable()
            // needed (a second focus target would make the FocusRequester
            // attach to a node onFocusChanged doesn't observe).
            .clickable { runCatching { onSelect() } }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = if (isExpanded) Arrangement.Start else Arrangement.Center,
    ) {
        // Icon circle
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(iconBg),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = painterResource(iconRes),
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(18.dp),
            )
        }

        // Label — always composed but width-animated so it slides in/out
        val labelWidth by animateDpAsState(
            targetValue = if (isExpanded) 140.dp else 0.dp,
            animationSpec = tween(durationMillis = 150, easing = FastOutSlowInEasing),
            label = "labelWidth",
        )
        if (labelWidth > 0.dp) {
            Spacer(modifier = Modifier.width(12.dp))
            Box(modifier = Modifier.width(labelWidth)) {
                Text(
                    text = androidx.compose.ui.res.stringResource(labelRes),
                    color = labelColor,
                    fontSize = 14.sp,
                    fontWeight = if (isSelected) FontWeight.W600 else FontWeight.W400,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile sidebar helpers (matches ProfileSelectScreen palette)
// ─────────────────────────────────────────────────────────────────────────────

private val ProfileSidebarColors = listOf(
    Color(0xFFE50914), Color(0xFF6366F1), Color(0xFF8B5CF6),
    Color(0xFFEC4899), Color(0xFFF59E0B), Color(0xFF10B981),
    Color(0xFF06B6D4), Color(0xFF3B82F6), Color(0xFFEF4444),
    Color(0xFF14B8A6), Color(0xFFF97316), Color(0xFFA855F7),
)

private fun ProfileSidebarIcon(codePoint: Int): androidx.compose.ui.graphics.vector.ImageVector = when (codePoint) {
    0xe4ff -> Icons.Filled.Person
    0xe038 -> Icons.Filled.Movie
    0xe30f -> Icons.Filled.SportsEsports
    0xe301 -> Icons.Filled.MusicNote
    0xe838 -> Icons.Filled.Star
    0xe558 -> Icons.Filled.RocketLaunch
    0xe06d -> Icons.Filled.AutoAwesome
    0xe91a -> Icons.Filled.Pets
    0xe3a8 -> Icons.Filled.Brush
    0xe0e3 -> Icons.Filled.Psychology
    0xe0ca -> Icons.Filled.Public
    0xe537 -> Icons.Filled.Bolt
    else -> Icons.Filled.Person
}
