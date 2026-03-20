--[[
╔══════════════════════════════════════════════════════════════════════╗
║         ENVIRONMENT DEBUG & SPECTATOR SUITE  v2.4.0                 ║
║         Developed for high-performance mobile Roblox environments    ║
║         Delta-compatible | RenderStepped-optimized | Luau strict     ║
╚══════════════════════════════════════════════════════════════════════╝
--]]

-- ============================================================
--  GLOBAL CONFIGURATION TABLE
--  All tunable constants live here. No magic numbers elsewhere.
-- ============================================================
local Config = {
    -- ── Suite Identity ──────────────────────────────────────
    SuiteTitle          = "ENV DEBUG SUITE",
    SuiteVersion        = "2.4.0",

    -- ── Active Guidance (Camera) ─────────────────────────────
    GuidanceSmoothingAlpha      = 0.1,          -- CFrame lerp alpha per frame
    GuidanceCircleOfInfluence   = 300,          -- Screen-space radius (px) for target detection
    GuidanceFOV                 = 70,           -- Camera FieldOfView while guidance is active
    GuidancePitchOffset         = 10,           -- Degrees above target to look at

    -- ── Identity Visualization (Visuals) ────────────────────
    HighlightFillColor          = Color3.fromRGB(0,   200, 255),
    HighlightOutlineColor       = Color3.fromRGB(255, 255, 255),
    HighlightFillTransparency   = 0.45,
    HighlightOutlineTransparency = 0.0,
    BillboardSize               = UDim2.new(0, 120, 0, 40),
    BillboardStudsOffset        = Vector3.new(0, 3.2, 0),
    HealthBarFullColor          = Color3.fromRGB(60,  220, 80),
    HealthBarLowColor           = Color3.fromRGB(230, 60,  60),
    NameLabelColor              = Color3.fromRGB(255, 255, 255),

    -- ── Physical Constraints (Movement) ─────────────────────
    DefaultWalkSpeed    = 16,
    ModifiedWalkSpeed   = 32,
    DefaultJumpHeight   = 7.2,
    ModifiedJumpHeight  = 14,

    -- ── Draggable GUI ────────────────────────────────────────
    PanelWidth          = 260,
    PanelHeight         = 340,
    PanelDefaultPos     = UDim2.new(0, 20, 0, 60),
    PanelBgColor        = Color3.fromRGB(10,  12,  18),
    PanelBorderColor    = Color3.fromRGB(0,   180, 255),
    AccentColor         = Color3.fromRGB(0,   200, 255),
    DimColor            = Color3.fromRGB(140, 160, 190),
    ToggleOnColor       = Color3.fromRGB(0,   220, 100),
    ToggleOffColor      = Color3.fromRGB(80,  80,  100),
    TextFont            = Enum.Font.Code,
    TitleFont           = Enum.Font.GothamBold,

    -- ── Performance ──────────────────────────────────────────
    VisualizationRefreshRate    = 0.25,  -- seconds between billboard refresh sweeps
    RenderSteppedPriority       = Enum.RenderPriority.Camera.Value + 1,
}

-- ============================================================
--  SERVICE ACQUISITION
-- ============================================================
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")

local LocalPlayer       = Players.LocalPlayer
local PlayerGui         = LocalPlayer:WaitForChild("PlayerGui")
local CurrentCamera     = workspace.CurrentCamera

-- ============================================================
--  SYSTEM DIAGNOSTIC STATE
--  Central truth table for all module toggles and runtime state.
-- ============================================================
local SystemDiagnostic = {
    GuidanceActive          = false,
    VisualizationActive     = false,
    WalkSpeedModified       = false,
    JumpHeightModified      = false,

    -- Runtime caches
    TargetAcquisitionHandle = nil,   -- Current guidance target character
    EnvironmentalMapping    = {},    -- { [player] = { highlight, billboard } }

    -- Drag state
    DragActive              = false,
    DragOffset              = Vector2.new(0, 0),
}

-- ============================================================
--  UTILITY HELPERS
-- ============================================================

--- Returns the local character's Humanoid safely.
local function GetLocalHumanoid(): Humanoid?
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChildOfClass("Humanoid")
end

--- WorldToViewportPoint wrapper that also checks viewport depth.
local function IsOnScreen(worldPos: Vector3): (boolean, Vector2)
    local viewportPos, onScreen = CurrentCamera:WorldToViewportPoint(worldPos)
    return onScreen and viewportPos.Z > 0, Vector2.new(viewportPos.X, viewportPos.Y)
end

--- Linear interpolation for numbers.
local function Lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

--- Clamp a number.
local function Clamp(v: number, min: number, max: number): number
    return math.max(min, math.min(max, v))
end

-- ============================================================
--  MODULE 1 ── ACTIVE GUIDANCE (Camera System)
-- ============================================================

--[[
    TargetAcquisition_FindNearest
    Scans all players' HumanoidRootParts and returns the character
    whose screen-space position falls within Config.GuidanceCircleOfInfluence
    and is closest to the viewport centre.
    Returns: (Character | nil, screenPos: Vector2 | nil)
--]]
local function TargetAcquisition_FindNearest(): (Model?, Vector2?)
    local viewportSize   = CurrentCamera.ViewportSize
    local screenCentre   = viewportSize * 0.5
    local radiusSq       = Config.GuidanceCircleOfInfluence ^ 2
    local bestDistanceSq = math.huge
    local bestCharacter: Model? = nil
    local bestScreenPos: Vector2? = nil

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local char = player.Character
        if not char then continue end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end

        local onScreen, screenPos = IsOnScreen(hrp.Position)
        if not onScreen then continue end

        local delta    = screenPos - screenCentre
        local distanceSq = delta.X * delta.X + delta.Y * delta.Y

        if distanceSq <= radiusSq and distanceSq < bestDistanceSq then
            bestDistanceSq  = distanceSq
            bestCharacter   = char
            bestScreenPos   = screenPos
        end
    end

    return bestCharacter, bestScreenPos
end

--[[
    ActiveGuidance_Step
    Called every RenderStepped frame when guidance is active.
    Smoothly lerps the camera CFrame toward the acquired target.
--]]
local function ActiveGuidance_Step()
    if not SystemDiagnostic.GuidanceActive then return end

    local targetChar, _ = TargetAcquisition_FindNearest()
    SystemDiagnostic.TargetAcquisitionHandle = targetChar

    if not targetChar then return end

    local hrp = targetChar:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    -- Desired camera position: slightly behind & above local character
    local localChar = LocalPlayer.Character
    if not localChar then return end
    local localHRP = localChar:FindFirstChild("HumanoidRootPart")
    if not localHRP then return end

    -- Compute a look-at CFrame from local HRP to target HRP
    local origin    = localHRP.Position + Vector3.new(0, 1.5, 0)
    local targetPos = hrp.Position       + Vector3.new(0, 1.5, 0)
    local desiredCF = CFrame.lookAt(origin, targetPos)
                       * CFrame.Angles(math.rad(-Config.GuidancePitchOffset), 0, 0)

    CurrentCamera.CFrame = CurrentCamera.CFrame:Lerp(desiredCF, Config.GuidanceSmoothingAlpha)
    CurrentCamera.FieldOfView = Lerp(
        CurrentCamera.FieldOfView,
        Config.GuidanceFOV,
        Config.GuidanceSmoothingAlpha
    )
end

-- ============================================================
--  MODULE 2 ── IDENTITY VISUALIZATION (Visuals)
-- ============================================================

--[[
    EnvironmentalMapping_BuildBillboard
    Creates a BillboardGui with a name label and a health bar
    parented to the given character's HumanoidRootPart.
--]]
local function EnvironmentalMapping_BuildBillboard(character: Model, playerName: string): BillboardGui
    local hrp       = character:WaitForChild("HumanoidRootPart", 5)
    local billboard = Instance.new("BillboardGui")
    billboard.Name           = "SuiteIdentityBoard"
    billboard.Adornee        = hrp
    billboard.Size           = Config.BillboardSize
    billboard.StudsOffset    = Config.BillboardStudsOffset
    billboard.AlwaysOnTop    = true
    billboard.LightInfluence = 0
    billboard.ResetOnSpawn   = false

    -- Name label
    local nameLabel      = Instance.new("TextLabel")
    nameLabel.Name       = "NameTag"
    nameLabel.Size       = UDim2.new(1, 0, 0.55, 0)
    nameLabel.Position   = UDim2.new(0, 0, 0, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text       = playerName
    nameLabel.TextColor3 = Config.NameLabelColor
    nameLabel.Font       = Config.TitleFont
    nameLabel.TextScaled = true
    nameLabel.ZIndex     = 5
    nameLabel.Parent     = billboard

    -- Health bar background
    local hpBG         = Instance.new("Frame")
    hpBG.Name          = "HealthBarBG"
    hpBG.Size          = UDim2.new(1, 0, 0.28, 0)
    hpBG.Position      = UDim2.new(0, 0, 0.68, 0)
    hpBG.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
    hpBG.BorderSizePixel  = 0
    hpBG.ZIndex           = 4
    hpBG.Parent           = billboard
    Instance.new("UICorner", hpBG).CornerRadius = UDim.new(0, 3)

    -- Health bar fill
    local hpFill         = Instance.new("Frame")
    hpFill.Name          = "HealthBarFill"
    hpFill.Size          = UDim2.new(1, 0, 1, 0)
    hpFill.BackgroundColor3 = Config.HealthBarFullColor
    hpFill.BorderSizePixel  = 0
    hpFill.ZIndex           = 5
    hpFill.Parent           = hpBG
    Instance.new("UICorner", hpFill).CornerRadius = UDim.new(0, 3)

    billboard.Parent = PlayerGui
    return billboard
end

--[[
    EnvironmentalMapping_Apply
    Attaches a Highlight + BillboardGui to every non-local player.
    Idempotent — safe to call repeatedly.
--]]
local function EnvironmentalMapping_Apply()
    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        if SystemDiagnostic.EnvironmentalMapping[player] then continue end

        local char = player.Character
        if not char then continue end

        -- Highlight
        local highlight                     = Instance.new("Highlight")
        highlight.Name                      = "SuiteHighlight"
        highlight.FillColor                 = Config.HighlightFillColor
        highlight.OutlineColor              = Config.HighlightOutlineColor
        highlight.FillTransparency          = Config.HighlightFillTransparency
        highlight.OutlineTransparency       = Config.HighlightOutlineTransparency
        highlight.DepthMode                 = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Adornee                   = char
        highlight.Parent                    = char

        -- Billboard
        local billboard = EnvironmentalMapping_BuildBillboard(char, player.DisplayName)

        SystemDiagnostic.EnvironmentalMapping[player] = {
            Highlight  = highlight,
            Billboard  = billboard,
            Character  = char,
        }
    end
end

--[[
    EnvironmentalMapping_Remove
    Cleans up all Highlight and BillboardGui instances.
--]]
local function EnvironmentalMapping_Remove()
    for player, data in pairs(SystemDiagnostic.EnvironmentalMapping) do
        if data.Highlight  and data.Highlight.Parent  then data.Highlight:Destroy()  end
        if data.Billboard  and data.Billboard.Parent  then data.Billboard:Destroy()  end
        SystemDiagnostic.EnvironmentalMapping[player] = nil
    end
end

--[[
    EnvironmentalMapping_RefreshHealthBars
    Updates health bar fill widths & colours for all tracked players.
    Runs on a low-frequency task loop (not RenderStepped) for efficiency.
--]]
local function EnvironmentalMapping_RefreshHealthBars()
    for player, data in pairs(SystemDiagnostic.EnvironmentalMapping) do
        if not (data.Character and data.Character.Parent) then
            -- Character left/respawned; clean up stale entry
            if data.Highlight  and data.Highlight.Parent  then data.Highlight:Destroy()  end
            if data.Billboard  and data.Billboard.Parent  then data.Billboard:Destroy()  end
            SystemDiagnostic.EnvironmentalMapping[player] = nil
            continue
        end

        local humanoid = data.Character:FindFirstChildOfClass("Humanoid")
        if not humanoid then continue end

        local hpPct  = Clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
        local board  = data.Billboard
        if not (board and board.Parent) then continue end

        local hpFill = board:FindFirstChild("HealthBarBG")
                       and board.HealthBarBG:FindFirstChild("HealthBarFill")
        if hpFill then
            hpFill.Size           = UDim2.new(hpPct, 0, 1, 0)
            hpFill.BackgroundColor3 = hpPct > 0.5
                and Config.HealthBarFullColor
                or  Config.HealthBarLowColor
        end

        local nameTag = board:FindFirstChild("NameTag")
        if nameTag then
            nameTag.Text = string.format("%s  %d%%", player.DisplayName, math.floor(hpPct * 100))
        end
    end
end

-- ============================================================
--  MODULE 3 ── PHYSICAL CONSTRAINTS (Movement)
-- ============================================================

local function PhysicalConstraints_SetWalkSpeed(modified: boolean)
    local humanoid = GetLocalHumanoid()
    if not humanoid then return end
    humanoid.WalkSpeed = modified and Config.ModifiedWalkSpeed or Config.DefaultWalkSpeed
    SystemDiagnostic.WalkSpeedModified = modified
end

local function PhysicalConstraints_SetJumpHeight(modified: boolean)
    local humanoid = GetLocalHumanoid()
    if not humanoid then return end
    humanoid.JumpHeight = modified and Config.ModifiedJumpHeight or Config.DefaultJumpHeight
    SystemDiagnostic.JumpHeightModified = modified
end

-- Reset constraints on character respawn
local function PhysicalConstraints_Reset()
    SystemDiagnostic.WalkSpeedModified  = false
    SystemDiagnostic.JumpHeightModified = false
end

-- ============================================================
--  GUI CONSTRUCTION
-- ============================================================

local ScreenGui       = Instance.new("ScreenGui")
ScreenGui.Name        = "EnvironmentDebugSuite"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent      = PlayerGui

-- ── Main Panel ──────────────────────────────────────────────
local MainPanel             = Instance.new("Frame")
MainPanel.Name              = "MainPanel"
MainPanel.Size              = UDim2.new(0, Config.PanelWidth, 0, Config.PanelHeight)
MainPanel.Position          = Config.PanelDefaultPos
MainPanel.BackgroundColor3  = Config.PanelBgColor
MainPanel.BorderSizePixel   = 0
MainPanel.ClipsDescendants  = true
MainPanel.Parent            = ScreenGui

-- Outer border via UIStroke
local stroke             = Instance.new("UIStroke", MainPanel)
stroke.Color             = Config.PanelBorderColor
stroke.Thickness         = 1.2
stroke.Transparency      = 0.3

-- Corner rounding
Instance.new("UICorner", MainPanel).CornerRadius = UDim.new(0, 6)

-- Subtle inner gradient
local gradient           = Instance.new("UIGradient", MainPanel)
gradient.Color           = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(16, 20, 32)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(8,  10, 16)),
})
gradient.Rotation        = 135

-- ── Title Bar (drag handle) ─────────────────────────────────
local TitleBar              = Instance.new("Frame")
TitleBar.Name               = "TitleBar"
TitleBar.Size               = UDim2.new(1, 0, 0, 34)
TitleBar.BackgroundColor3   = Color3.fromRGB(0, 160, 210)
TitleBar.BorderSizePixel    = 0
TitleBar.ZIndex             = 3
TitleBar.Parent             = MainPanel
Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0, 6)

-- Crop bottom corners of title bar so it merges with panel
local titleCropFix          = Instance.new("Frame")
titleCropFix.Size           = UDim2.new(1, 0, 0.5, 0)
titleCropFix.Position       = UDim2.new(0, 0, 0.5, 0)
titleCropFix.BackgroundColor3 = Color3.fromRGB(0, 160, 210)
titleCropFix.BorderSizePixel  = 0
titleCropFix.ZIndex           = 3
titleCropFix.Parent           = TitleBar

local titleLabel            = Instance.new("TextLabel")
titleLabel.Size             = UDim2.new(1, -10, 1, 0)
titleLabel.Position         = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text             = "⬡  " .. Config.SuiteTitle .. "  v" .. Config.SuiteVersion
titleLabel.TextColor3       = Color3.fromRGB(255, 255, 255)
titleLabel.Font             = Config.TitleFont
titleLabel.TextSize         = 11
titleLabel.TextXAlignment   = Enum.TextXAlignment.Left
titleLabel.ZIndex           = 4
titleLabel.Parent           = TitleBar

-- ── Content Scroll ─────────────────────────────────────────
local ContentFrame          = Instance.new("Frame")
ContentFrame.Name           = "ContentFrame"
ContentFrame.Size           = UDim2.new(1, 0, 1, -34)
ContentFrame.Position       = UDim2.new(0, 0, 0, 34)
ContentFrame.BackgroundTransparency = 1
ContentFrame.ClipsDescendants = false
ContentFrame.Parent         = MainPanel

local Layout                = Instance.new("UIListLayout", ContentFrame)
Layout.SortOrder            = Enum.SortOrder.LayoutOrder
Layout.Padding              = UDim.new(0, 1)

local Padding               = Instance.new("UIPadding", ContentFrame)
Padding.PaddingLeft         = UDim.new(0, 10)
Padding.PaddingRight        = UDim.new(0, 10)
Padding.PaddingTop          = UDim.new(0, 8)

-- ============================================================
--  REUSABLE SECTION BUILDER
-- ============================================================

local function BuildSectionHeader(labelText: string, order: number): Frame
    local header              = Instance.new("Frame")
    header.Name               = "Header_" .. labelText
    header.Size               = UDim2.new(1, 0, 0, 22)
    header.BackgroundTransparency = 1
    header.LayoutOrder        = order
    header.Parent             = ContentFrame

    local bar                 = Instance.new("Frame", header)
    bar.Size                  = UDim2.new(1, 0, 0, 1)
    bar.Position              = UDim2.new(0, 0, 0.5, 0)
    bar.BackgroundColor3      = Config.AccentColor
    bar.BackgroundTransparency = 0.6
    bar.BorderSizePixel       = 0

    local lbl                 = Instance.new("TextLabel", header)
    lbl.Size                  = UDim2.new(0, 140, 1, 0)
    lbl.Position              = UDim2.new(0, 0, 0, 0)
    lbl.BackgroundColor3      = Config.PanelBgColor
    lbl.BorderSizePixel       = 0
    lbl.Text                  = "  " .. labelText
    lbl.TextColor3            = Config.AccentColor
    lbl.Font                  = Config.TitleFont
    lbl.TextSize              = 9
    lbl.TextXAlignment        = Enum.TextXAlignment.Left

    return header
end

--[[
    BuildToggleRow
    Creates a labeled row with a pill toggle button.
    onToggle(isOn: boolean) is called when the button is pressed.
--]]
local function BuildToggleRow(
    labelText    : string,
    subText      : string,
    order        : number,
    initialState : boolean,
    onToggle     : (boolean) -> ()
): Frame

    local row               = Instance.new("Frame")
    row.Name                = "Row_" .. labelText
    row.Size                = UDim2.new(1, 0, 0, 44)
    row.BackgroundTransparency = 1
    row.LayoutOrder         = order
    row.Parent              = ContentFrame

    local lbl               = Instance.new("TextLabel", row)
    lbl.Size                = UDim2.new(0.62, 0, 0.55, 0)
    lbl.Position            = UDim2.new(0, 0, 0.05, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                = labelText
    lbl.TextColor3          = Config.NameLabelColor
    lbl.Font                = Config.TextFont
    lbl.TextSize            = 12
    lbl.TextXAlignment      = Enum.TextXAlignment.Left

    local sub               = Instance.new("TextLabel", row)
    sub.Size                = UDim2.new(0.62, 0, 0.38, 0)
    sub.Position            = UDim2.new(0, 0, 0.58, 0)
    sub.BackgroundTransparency = 1
    sub.Text                = subText
    sub.TextColor3          = Config.DimColor
    sub.Font                = Config.TextFont
    sub.TextSize            = 9
    sub.TextXAlignment      = Enum.TextXAlignment.Left

    -- Toggle pill
    local pill              = Instance.new("TextButton", row)
    pill.Name               = "Toggle"
    pill.Size               = UDim2.new(0, 52, 0, 24)
    pill.Position           = UDim2.new(1, -52, 0.5, -12)
    pill.BackgroundColor3   = initialState and Config.ToggleOnColor or Config.ToggleOffColor
    pill.BorderSizePixel    = 0
    pill.Text               = initialState and "ON" or "OFF"
    pill.TextColor3         = Color3.fromRGB(255, 255, 255)
    pill.Font               = Config.TitleFont
    pill.TextSize           = 10
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)

    local isOn = initialState
    pill.MouseButton1Click:Connect(function()
        isOn = not isOn
        local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad)
        TweenService:Create(pill, tweenInfo, {
            BackgroundColor3 = isOn and Config.ToggleOnColor or Config.ToggleOffColor,
        }):Play()
        pill.Text = isOn and "ON" or "OFF"
        onToggle(isOn)
    end)

    return row
end

-- ============================================================
--  BUILD MODULE ROWS
-- ============================================================

-- ── Section: Active Guidance ────────────────────────────────
BuildSectionHeader("ACTIVE GUIDANCE  ·  Camera", 10)

BuildToggleRow(
    "Guidance System",
    string.format("Radius: %dpx  |  α: %.2f", Config.GuidanceCircleOfInfluence, Config.GuidanceSmoothingAlpha),
    11,
    SystemDiagnostic.GuidanceActive,
    function(isOn)
        SystemDiagnostic.GuidanceActive = isOn
        if not isOn then
            -- Restore FOV
            TweenService:Create(CurrentCamera, TweenInfo.new(0.4), {FieldOfView = 70}):Play()
            SystemDiagnostic.TargetAcquisitionHandle = nil
        end
    end
)

-- ── Section: Identity Visualization ────────────────────────
BuildSectionHeader("IDENTITY VISUALIZATION  ·  Visuals", 20)

BuildToggleRow(
    "Player Highlights",
    "Highlight + BillboardGui overlay",
    21,
    SystemDiagnostic.VisualizationActive,
    function(isOn)
        SystemDiagnostic.VisualizationActive = isOn
        if isOn then
            EnvironmentalMapping_Apply()
        else
            EnvironmentalMapping_Remove()
        end
    end
)

-- ── Section: Physical Constraints ──────────────────────────
BuildSectionHeader("PHYSICAL CONSTRAINTS  ·  Movement", 30)

BuildToggleRow(
    "Walk Speed Boost",
    string.format("Default: %d  →  Modified: %d", Config.DefaultWalkSpeed, Config.ModifiedWalkSpeed),
    31,
    SystemDiagnostic.WalkSpeedModified,
    function(isOn)
        PhysicalConstraints_SetWalkSpeed(isOn)
    end
)

BuildToggleRow(
    "Jump Height Boost",
    string.format("Default: %.1f  →  Modified: %d", Config.DefaultJumpHeight, Config.ModifiedJumpHeight),
    32,
    SystemDiagnostic.JumpHeightModified,
    function(isOn)
        PhysicalConstraints_SetJumpHeight(isOn)
    end
)

-- ── Footer ───────────────────────────────────────────────────
local footer            = Instance.new("TextLabel", ContentFrame)
footer.Size             = UDim2.new(1, 0, 0, 20)
footer.BackgroundTransparency = 1
footer.Text             = "⬡  SYSTEM DIAGNOSTIC  ·  IDLE"
footer.TextColor3       = Config.DimColor
footer.Font             = Config.TextFont
footer.TextSize         = 9
footer.LayoutOrder      = 99
footer.TextXAlignment   = Enum.TextXAlignment.Left

-- ============================================================
--  DRAGGABLE INTERFACE  (UserInputService)
-- ============================================================

local function ConnectDraggable(handle: GuiObject, panel: GuiObject)
    local dragging      = false
    local dragStartPos  = Vector2.new()
    local panelStartPos = Vector2.new()

    local function GetAbsolutePosition(): Vector2
        return Vector2.new(
            panel.Position.X.Offset,
            panel.Position.Y.Offset
        )
    end

    -- Input began on the drag handle
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging        = true
            dragStartPos    = input.Position
            panelStartPos   = GetAbsolutePosition()
            SystemDiagnostic.DragActive = true
        end
    end)

    -- Track movement globally to avoid losing drag when cursor moves fast
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end

        local delta      = input.Position - dragStartPos
        local newX       = panelStartPos.X + delta.X
        local newY       = panelStartPos.Y + delta.Y

        -- Clamp to viewport
        local vp         = workspace.CurrentCamera.ViewportSize
        newX = Clamp(newX, 0, vp.X - Config.PanelWidth)
        newY = Clamp(newY, 0, vp.Y - Config.PanelHeight)

        panel.Position   = UDim2.new(0, newX, 0, newY)
    end)

    -- End drag on any release
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            SystemDiagnostic.DragActive = false
        end
    end)
end

ConnectDraggable(TitleBar, MainPanel)

-- ============================================================
--  RENDERSTEPPED LOOP  (Camera Guidance + footer diagnostics)
-- ============================================================

RunService:BindToRenderStep(
    "SuiteGuidanceStep",
    Config.RenderSteppedPriority,
    function()
        -- Active Guidance frame step
        if SystemDiagnostic.GuidanceActive then
            ActiveGuidance_Step()
        end

        -- Footer status update (lightweight string work)
        local targetName = "—"
        if SystemDiagnostic.TargetAcquisitionHandle then
            local player = Players:GetPlayerFromCharacter(SystemDiagnostic.TargetAcquisitionHandle)
            if player then targetName = player.DisplayName end
        end

        local status = SystemDiagnostic.GuidanceActive
            and ("⬡  GUIDANCE LOCK  ·  " .. targetName)
            or  "⬡  SYSTEM DIAGNOSTIC  ·  IDLE"

        if footer.Text ~= status then
            footer.Text = status
        end
    end
)

-- ============================================================
--  LOW-FREQUENCY TASK LOOPS
-- ============================================================

-- Billboard / health-bar refresh loop
task.spawn(function()
    while true do
        task.wait(Config.VisualizationRefreshRate)
        if SystemDiagnostic.VisualizationActive then
            EnvironmentalMapping_RefreshHealthBars()
        end
    end
end)

-- Poll for new players joining while visualization is active
task.spawn(function()
    while true do
        task.wait(3)
        if SystemDiagnostic.VisualizationActive then
            EnvironmentalMapping_Apply()
        end
    end
end)

-- ============================================================
--  CHARACTER LIFECYCLE HOOKS
-- ============================================================

local function OnCharacterAdded(character: Model)
    -- Re-apply movement constraints after respawn
    task.wait(0.5) -- wait for humanoid to initialise
    PhysicalConstraints_Reset()
    if SystemDiagnostic.WalkSpeedModified then
        PhysicalConstraints_SetWalkSpeed(true)
    end
    if SystemDiagnostic.JumpHeightModified then
        PhysicalConstraints_SetJumpHeight(true)
    end
end

local function OnPlayerAdded(player: Player)
    if player == LocalPlayer then return end
    player.CharacterAdded:Connect(function(char)
        -- Give the new character a chance to load its hierarchy
        task.wait(1)
        if SystemDiagnostic.VisualizationActive then
            -- Remove stale entry so Apply() rebuilds fresh
            local existing = SystemDiagnostic.EnvironmentalMapping[player]
            if existing then
                if existing.Highlight and existing.Highlight.Parent then existing.Highlight:Destroy() end
                if existing.Billboard and existing.Billboard.Parent then existing.Billboard:Destroy() end
                SystemDiagnostic.EnvironmentalMapping[player] = nil
            end
            EnvironmentalMapping_Apply()
        end
    end)
end

local function OnPlayerRemoving(player: Player)
    local data = SystemDiagnostic.EnvironmentalMapping[player]
    if data then
        if data.Highlight and data.Highlight.Parent then data.Highlight:Destroy() end
        if data.Billboard and data.Billboard.Parent then data.Billboard:Destroy() end
        SystemDiagnostic.EnvironmentalMapping[player] = nil
    end
end

-- Connect lifecycle events
LocalPlayer.CharacterAdded:Connect(OnCharacterAdded)

for _, player in ipairs(Players:GetPlayers()) do
    OnPlayerAdded(player)
end
Players.PlayerAdded:Connect(OnPlayerAdded)
Players.PlayerRemoving:Connect(OnPlayerRemoving)

-- ============================================================
--  INITIAL STATE  (apply if defaults are non-zero)
-- ============================================================
if LocalPlayer.Character then
    OnCharacterAdded(LocalPlayer.Character
end

print(string.format(
    "[EnvironmentDebugSuite] v%s loaded. Panel ready at (%d, %d).",
    Config.SuiteVersion,
    Config.PanelDefaultPos.X.Offset,
    Config.PanelDefaultPos.Y.Offset
))

-- EOF ──────────────────────────────────────────────────────────
