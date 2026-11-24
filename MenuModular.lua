--[[
    DEBUG CONTROL V1
    Roblox Luau - Delta Executor
    Client-side visual/debug utilities only.

    MAIN: Target tracking, drone hover, camera aim, hitbox visualization.
    ESP: Line, Box, Name, Distance, Highlight.
    KHAC: Fly, NoClip, WalkSpeed, AirJump, NightVision, FixLag.

    Security/authority note:
    Client-side code cannot grant server damage, bypass walls, disable
    server NPC AI, or guarantee damage protection. AttackHook is a safe
    extension point and intentionally does not invoke remote events.
]]

--============================================================
-- SERVICES
--============================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--============================================================
-- CONFIG / STATE
--============================================================
local Config = {
    ScanRange = 150,
    ScanInterval = 0.45,
    SafeHeight = 12,
    DroneHeightOffset = 6,
    FlySpeed = 45,
    WalkSpeed = 32,
    AimSmoothness = 0.18,
    HitboxVisualScale = 1.5,
    NightBrightness = 2,
}

local StateManager = {
    Enabled = {},
    Snapshot = {},
    Config = Config,
}

function StateManager:Set(name, value)
    self.Enabled[name] = value == true
end

function StateManager:Get(name)
    return self.Enabled[name] == true
end

function StateManager:Save(name, value)
    if self.Snapshot[name] == nil then
        self.Snapshot[name] = value
    end
end

function StateManager:Restore(name)
    local value = self.Snapshot[name]
    self.Snapshot[name] = nil
    return value
end

local function safeDestroy(obj)
    if obj then
        pcall(function() obj:Destroy() end)
    end
end

local function getCharacter()
    return LocalPlayer.Character
end

local function getHumanoid(model)
    return model and model:FindFirstChildOfClass("Humanoid") or nil
end

local function getRoot(model)
    if not model then return nil end
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if root and root:IsA("BasePart") then return root end
    return nil
end

local function isPlayerCharacter(model)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character == model then return true end
    end
    return false
end

local function isValidTarget(model)
    if not model or not model:IsA("Model") then return false end
    if model == getCharacter() or isPlayerCharacter(model) then return false end
    if not model:IsDescendantOf(Workspace) then return false end
    local hum = getHumanoid(model)
    local root = getRoot(model)
    return hum ~= nil and hum.Health > 0 and root ~= nil
end

local function getDistance(a, b)
    return (a.Position - b.Position).Magnitude
end

local function getRootAndHumanoid()
    local character = getCharacter()
    return getRoot(character), getHumanoid(character)
end

--============================================================
-- TARGET SCANNER
--============================================================
local TargetScanner = {
    Targets = {},
    LastScan = 0,
    CurrentTarget = nil,
}

function TargetScanner:Scan(force)
    local now = os.clock()
    if not force and now - self.LastScan < Config.ScanInterval then
        return self.Targets
    end
    self.LastScan = now

    local playerRoot = getRoot(getCharacter())
    if not playerRoot then
        self.Targets = {}
        self.CurrentTarget = nil
        return self.Targets
    end

    local found, seen = {}, {}
    for _, item in ipairs(Workspace:GetDescendants()) do
        if item:IsA("Model") and not seen[item] and isValidTarget(item) then
            seen[item] = true
            local root = getRoot(item)
            local distance = getDistance(playerRoot, root)
            if distance <= Config.ScanRange then
                table.insert(found, {
                    Model = item,
                    Root = root,
                    Humanoid = getHumanoid(item),
                    Distance = distance,
                })
            end
        end
    end

    table.sort(found, function(a, b)
        return a.Distance < b.Distance
    end)
    self.Targets = found

    local currentValid = false
    if self.CurrentTarget then
        for _, entry in ipairs(found) do
            if entry.Model == self.CurrentTarget then
                currentValid = true
                break
            end
        end
    end
    if not currentValid then
        self.CurrentTarget = found[1] and found[1].Model or nil
    end
    return found
end

function TargetScanner:GetCurrent()
    self:Scan(false)
    for _, entry in ipairs(self.Targets) do
        if entry.Model == self.CurrentTarget then return entry end
    end
    return nil
end

--============================================================
-- COMBAT / CAMERA DEBUG
--============================================================
local CombatEngine = {
    DronePosition = nil,
    DroneGyro = nil,
    AimTarget = nil,
}

-- Hook de tuy bien cho game do ban phat trien.
-- Mac dinh khong goi RemoteEvent va khong tao damage.
function CombatEngine:AttackHook(targetModel, mode)
    if not isValidTarget(targetModel) then return false end
    return false
end

function CombatEngine:StopDrone()
    safeDestroy(self.DronePosition)
    safeDestroy(self.DroneGyro)
    self.DronePosition, self.DroneGyro = nil, nil
end

function CombatEngine:StartDrone()
    local root = getRoot(getCharacter())
    local target = TargetScanner:GetCurrent()
    if not root or not target then return end
    self:StopDrone()

    local position = Instance.new("BodyPosition")
    position.Name = "DebugControl_DronePosition"
    position.MaxForce = Vector3.new(1e6, 1e6, 1e6)
    position.P = 15000
    position.D = 1400
    position.Position = target.Root.Position + Vector3.new(0, Config.SafeHeight, 0)
    position.Parent = root

    local gyro = Instance.new("BodyGyro")
    gyro.Name = "DebugControl_DroneGyro"
    gyro.MaxTorque = Vector3.new(1e6, 1e6, 1e6)
    gyro.P = 10000
    gyro.D = 900
    gyro.CFrame = root.CFrame
    gyro.Parent = root

    self.DronePosition, self.DroneGyro = position, gyro
end

function CombatEngine:UpdateDrone()
    if not self.DronePosition then return end
    local target = TargetScanner:GetCurrent()
    if not target or not self.DronePosition.Parent then
        self:StopDrone()
        return
    end
    self.DronePosition.Position =
        target.Root.Position + Vector3.new(0, Config.SafeHeight, 0)
end

function CombatEngine:UpdateAim()
    local target = TargetScanner:GetCurrent()
    local camera = Workspace.CurrentCamera
    if not target or not camera then
        self.AimTarget = nil
        return
    end
    local part = target.Model:FindFirstChild("Head") or target.Root
    local desired = CFrame.lookAt(camera.CFrame.Position, part.Position)
    camera.CFrame = camera.CFrame:Lerp(
        desired, math.clamp(Config.AimSmoothness, 0.01, 1)
    )
    self.AimTarget = target.Model
end

--============================================================
-- ESP ENGINE
--============================================================
local EspEngine = {
    Objects = {},
    Enabled = {},
}

local espFolder = Instance.new("Folder")
espFolder.Name = "DebugControl_ESP"
espFolder.Parent = PlayerGui

function EspEngine:Create(model)
    if self.Objects[model] then return self.Objects[model] end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "DebugESP_Label"
    billboard.Size = UDim2.fromOffset(190, 30)
    billboard.StudsOffset = Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Enabled = false

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = Color3.fromRGB(70, 255, 180)
    label.TextStrokeTransparency = 0.25
    label.Parent = billboard

    local highlight = Instance.new("Highlight")
    highlight.Name = "DebugESP_Highlight"
    highlight.FillColor = Color3.fromRGB(40, 220, 160)
    highlight.OutlineColor = Color3.new(1, 1, 1)
    highlight.FillTransparency = 0.72
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = false
    highlight.Adornee = model
    highlight.Parent = espFolder

    local box = Instance.new("BoxHandleAdornment")
    box.Name = "DebugESP_Box"
    box.Color3 = Color3.fromRGB(70, 255, 180)
    box.Transparency = 0.65
    box.AlwaysOnTop = true
    box.ZIndex = 5
    box.Visible = false

    billboard.Parent = espFolder
    local data = {
        Billboard = billboard,
        Label = label,
        Highlight = highlight,
        Box = box,
    }
    self.Objects[model] = data
    return data
end

function EspEngine:Cleanup(model)
    local data = self.Objects[model]
    if not data then return end
    safeDestroy(data.Billboard)
    safeDestroy(data.Highlight)
    safeDestroy(data.Box)
    self.Objects[model] = nil
end

function EspEngine:CleanupAll()
    local models = {}
    for model in pairs(self.Objects) do table.insert(models, model) end
    for _, model in ipairs(models) do self:Cleanup(model) end
end

function EspEngine:SetFeature(name, enabled)
    self.Enabled[name] = enabled
    if not enabled then
        for _, data in pairs(self.Objects) do
            if name == "Esp Hologram" and data.Highlight then
                data.Highlight.Enabled = false
            elseif name == "Esp Box" and data.Box then
                data.Box.Visible = false
            elseif name == "Esp Name" or name == "Esp Distance" then
                data.Label.Text = ""
                data.Billboard.Enabled = false
            end
        end
    end
end

function EspEngine:Update()
    local targets = TargetScanner:Scan(false)
    local active = {}
    local anyEnabled = self.Enabled["Esp Line"] or self.Enabled["Esp Box"]
        or self.Enabled["Esp Name"] or self.Enabled["Esp Distance"]
        or self.Enabled["Esp Hologram"]

    if not anyEnabled then
        self:CleanupAll()
        return
    end

    for _, entry in ipairs(targets) do
        local model = entry.Model
        active[model] = true
        local data = self:Create(model)
        data.Billboard.Adornee = entry.Root

        local parts = {}
        if self.Enabled["Esp Name"] then table.insert(parts, model.Name) end
        if self.Enabled["Esp Distance"] then
            table.insert(parts, string.format("%.0f studs", entry.Distance))
        end
        data.Label.Text = table.concat(parts, " | ")
        data.Billboard.Enabled = #parts > 0

        data.Highlight.Enabled = self.Enabled["Esp Hologram"]

        if self.Enabled["Esp Box"] then
            local ok, size = pcall(function() return model:GetExtentsSize() end)
            if ok then
                data.Box.Adornee = entry.Root
                data.Box.Size = size
                data.Box.CFrame = CFrame.new()
                data.Box.Visible = true
                data.Box.Parent = entry.Root
            end
        else
            data.Box.Visible = false
        end
    end

    local remove = {}
    for model in pairs(self.Objects) do
        if not active[model] then table.insert(remove, model) end
    end
    for _, model in ipairs(remove) do self:Cleanup(model) end
end

--============================================================
-- MOVEMENT / WORLD
--============================================================
local MovementAndWorld = {
    NoClipSnapshot = {},
    FlyAttachment = nil,
    FlyVelocity = nil,
    FlyGyro = nil,
    NightSnapshot = nil,
    LightingEffects = {},
}

function MovementAndWorld:SetSpeed(enabled)
    local _, hum = getRootAndHumanoid()
    if not hum then return end
    if enabled then
        StateManager:Save("WalkSpeed", hum.WalkSpeed)
        hum.WalkSpeed = Config.WalkSpeed
    else
        local old = StateManager:Restore("WalkSpeed")
        if old then hum.WalkSpeed = old end
    end
end

function MovementAndWorld:SetNoClip(enabled)
    local character = getCharacter()
    if not character then return end

    if enabled then
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                if self.NoClipSnapshot[part] == nil then
                    self.NoClipSnapshot[part] = part.CanCollide
                end
                part.CanCollide = false
            end
        end
    else
        for part, old in pairs(self.NoClipSnapshot) do
            if part and part.Parent then
                pcall(function() part.CanCollide = old end)
            end
        end
        self.NoClipSnapshot = {}
    end
end

function MovementAndWorld:StopFly()
    safeDestroy(self.FlyVelocity)
    safeDestroy(self.FlyGyro)
    safeDestroy(self.FlyAttachment)
    self.FlyVelocity, self.FlyGyro, self.FlyAttachment = nil, nil, nil
end

function MovementAndWorld:StartFly()
    local root = getRoot(getCharacter())
    if not root then return end
    self:StopFly()

    local attachment = Instance.new("Attachment")
    attachment.Name = "DebugControl_FlyAttachment"
    attachment.Parent = root

    local velocity = Instance.new("LinearVelocity")
    velocity.Name = "DebugControl_FlyVelocity"
    velocity.Attachment0 = attachment
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    velocity.MaxForce = math.huge
    velocity.VectorVelocity = Vector3.zero
    velocity.Parent = root

    local gyro = Instance.new("AlignOrientation")
    gyro.Name = "DebugControl_FlyOrientation"
    gyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
    gyro.Attachment0 = attachment
    gyro.MaxTorque = math.huge
    gyro.Responsiveness = 18
    gyro.CFrame = root.CFrame
    gyro.Parent = root

    self.FlyAttachment, self.FlyVelocity, self.FlyGyro =
        attachment, velocity, gyro
end

function MovementAndWorld:UpdateFly()
    if not self.FlyVelocity or not self.FlyVelocity.Parent then
        self:StopFly()
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local direction = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then
        direction += camera.CFrame.LookVector
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then
        direction -= camera.CFrame.LookVector
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then
        direction += camera.CFrame.RightVector
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then
        direction -= camera.CFrame.RightVector
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
        direction += Vector3.yAxis
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        direction -= Vector3.yAxis
    end

    if direction.Magnitude > 0 then
        direction = direction.Unit
    end
    self.FlyVelocity.VectorVelocity = direction * Config.FlySpeed
    self.FlyGyro.CFrame = camera.CFrame
end

function MovementAndWorld:SetNightVision(enabled)
    if enabled then
        if not self.NightSnapshot then
            self.NightSnapshot = {
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                FogEnd = Lighting.FogEnd,
                FogStart = Lighting.FogStart,
                GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end
        Lighting.Brightness = Config.NightBrightness
        Lighting.ClockTime = 14
        Lighting.FogEnd = 100000
        Lighting.FogStart = 0
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(170, 170, 170)
        Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
    elseif self.NightSnapshot then
        for property, value in pairs(self.NightSnapshot) do
            pcall(function() Lighting[property] = value end)
        end
        self.NightSnapshot = nil
    end
end

function MovementAndWorld:SetFixLag(enabled)
    if enabled then
        if next(self.LightingEffects) == nil then
            for _, effect in ipairs(Lighting:GetChildren()) do
                if effect:IsA("PostEffect") then
                    self.LightingEffects[effect] = effect.Enabled
                    effect.Enabled = false
                end
            end
        end
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
    else
        for effect, old in pairs(self.LightingEffects) do
            if effect and effect.Parent then
                pcall(function() effect.Enabled = old end)
            end
        end
        self.LightingEffects = {}
    end
end

--============================================================
-- UI
--============================================================
local UIController = {}
local oldGui = PlayerGui:FindFirstChild("DebugControlV1")
if oldGui then oldGui:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DebugControlV1"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.Size = UDim2.fromOffset(340, 440)
Main.Position = UDim2.new(0.5, -170, 0.5, -220)
Main.BackgroundColor3 = Color3.fromRGB(20, 23, 31)
Main.BorderSizePixel = 0
Main.Active = true
Main.Parent = ScreenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = Main

local Top = Instance.new("Frame")
Top.Size = UDim2.new(1, 0, 0, 42)
Top.BackgroundColor3 = Color3.fromRGB(31, 37, 49)
Top.BorderSizePixel = 0
Top.Parent = Main
Instance.new("UICorner", Top).CornerRadius = UDim.new(0, 10)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -85, 1, 0)
Title.Position = UDim2.fromOffset(12, 0)
Title.BackgroundTransparency = 1
Title.Text = "DEBUG CONTROL  V1"
Title.TextColor3 = Color3.fromRGB(100, 255, 190)
Title.Font = Enum.Font.GothamBold
Title.TextSize = 14
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Top

local Minimize = Instance.new("TextButton")
Minimize.Size = UDim2.fromOffset(34, 28)
Minimize.Position = UDim2.new(1, -40, 0, 7)
Minimize.Text = "—"
Minimize.TextSize = 18
Minimize.Font = Enum.Font.GothamBold
Minimize.TextColor3 = Color3.new(1, 1, 1)
Minimize.BackgroundColor3 = Color3.fromRGB(55, 65, 82)
Minimize.Parent = Top
Instance.new("UICorner", Minimize).CornerRadius = UDim.new(0, 6)

local Tabs = Instance.new("Frame")
Tabs.Position = UDim2.fromOffset(8, 50)
Tabs.Size = UDim2.new(1, -16, 0, 34)
Tabs.BackgroundTransparency = 1
Tabs.Parent = Main

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = Tabs

local Content = Instance.new("ScrollingFrame")
Content.Position = UDim2.fromOffset(8, 92)
Content.Size = UDim2.new(1, -16, 1, -100)
Content.BackgroundColor3 = Color3.fromRGB(25, 29, 39)
Content.BorderSizePixel = 0
Content.ScrollBarThickness = 4
Content.CanvasSize = UDim2.new()
Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
Content.Parent = Main
Instance.new("UICorner", Content).CornerRadius = UDim.new(0, 7)

local contentPadding = Instance.new("UIPadding")
contentPadding.PaddingTop = UDim.new(0, 8)
contentPadding.PaddingBottom = UDim.new(0, 8)
contentPadding.PaddingLeft = UDim.new(0, 8)
contentPadding.PaddingRight = UDim.new(0, 8)
contentPadding.Parent = Content

local contentLayout = Instance.new("UIListLayout")
contentLayout.Padding = UDim.new(0, 6)
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Parent = Content

local pages = {}
local tabButtons = {}
local currentTab = "Main"

local function makePage(name)
    local page = Instance.new("Frame")
    page.Name = name
    page.Size = UDim2.new(1, 0, 0, 0)
    page.AutomaticSize = Enum.AutomaticSize.Y
    page.BackgroundTransparency = 1
    page.Visible = false
    page.Parent = Content

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = page
    pages[name] = page
    return page
end

local function showTab(name)
    currentTab = name
    for tabName, page in pairs(pages) do
        page.Visible = tabName == name
    end
    for tabName, button in pairs(tabButtons) do
        button.BackgroundColor3 = tabName == name
            and Color3.fromRGB(30, 130, 100)
            or Color3.fromRGB(48, 55, 70)
    end
end

local function makeTab(name)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1/3, -5, 1, 0)
    button.Text = name
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.TextColor3 = Color3.new(1, 1, 1)
    button.BackgroundColor3 = Color3.fromRGB(48, 55, 70)
    button.Parent = Tabs
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
    tabButtons[name] = button
    button.MouseButton1Click:Connect(function() showTab(name) end)
end

local function makeSection(parent, text)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 25)
    label.BackgroundTransparency = 1
    label.Text = "  " .. text
    label.TextColor3 = Color3.fromRGB(100, 255, 190)
    label.TextSize = 12
    label.Font = Enum.Font.GothamBold
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = parent
end

local function makeToggle(parent, name, callback)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, 0, 0, 34)
    button.BackgroundColor3 = Color3.fromRGB(43, 49, 63)
    button.TextColor3 = Color3.fromRGB(235, 240, 248)
    button.Font = Enum.Font.Gotham
    button.TextSize = 12
    button.TextXAlignment = Enum.TextXAlignment.Left
    button.Parent = parent
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)

    local enabled = false
    local function refresh()
        button.Text = (enabled and "  [ON]  " or "  [OFF] ") .. name
        button.BackgroundColor3 = enabled
            and Color3.fromRGB(25, 105, 80)
            or Color3.fromRGB(43, 49, 63)
    end
    button.MouseButton1Click:Connect(function()
        enabled = not enabled
        StateManager:Set(name, enabled)
        refresh()
        if callback then
            local ok, err = pcall(callback, enabled)
            if not ok then warn("[DebugControl] " .. tostring(err)) end
        end
    end)
    refresh()
    return button
end

local function makeSlider(parent, labelText, initial, minimum, maximum, callback)
    local wrap = Instance.new("Frame")
    wrap.Size = UDim2.new(1, 0, 0, 48)
    wrap.BackgroundColor3 = Color3.fromRGB(36, 42, 55)
    wrap.Parent = parent
    Instance.new("UICorner", wrap).CornerRadius = UDim.new(0, 6)

    local label = Instance.new("TextLabel")
    label.Position = UDim2.fromOffset(8, 2)
    label.Size = UDim2.new(1, -16, 0, 19)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Font = Enum.Font.Gotham
    label.TextSize = 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = wrap

    local bar = Instance.new("Frame")
    bar.Position = UDim2.new(0, 8, 0, 27)
    bar.Size = UDim2.new(1, -16, 0, 9)
    bar.BackgroundColor3 = Color3.fromRGB(65, 73, 90)
    bar.Parent = wrap
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new((initial-minimum)/(maximum-minimum), 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(60, 220, 160)
    fill.Parent = bar
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local value = initial
    local dragging = false
    local function setFromX(x)
        local alpha = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        value = math.floor(minimum + (maximum - minimum) * alpha + 0.5)
        fill.Size = UDim2.new(alpha, 0, 1, 0)
        label.Text = labelText .. ": " .. tostring(value)
        callback(value)
    end
    label.Text = labelText .. ": " .. tostring(value)

    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    return wrap
end

makeTab("Main")
makeTab("Esp")
makeTab("Khác")

local mainPage = makePage("Main")
local espPage = makePage("Esp")
local otherPage = makePage("Khác")

-- MAIN TAB
makeSection(mainPage, "TARGET / COMBAT DEBUG")
makeToggle(mainPage, "Tele Dron", function(enabled)
    if enabled then CombatEngine:StartDrone()
    else CombatEngine:StopDrone() end
end)
makeToggle(mainPage, "Aimbot", function(enabled)
    if not enabled then CombatEngine.AimTarget = nil end
end)
makeToggle(mainPage, "Tele Kill", function(enabled)
    -- Chi dich chuyen toi gan muc tieu de kiem thu vi tri.
    if enabled then
        local target = TargetScanner:GetCurrent()
        local root = getRoot(getCharacter())
        if target and root then
            root.CFrame = target.Root.CFrame * CFrame.new(0, 0, 7)
        end
        StateManager:Set("Tele Kill", false)
        -- Nut la thao tac mot lan, khong tu gay sat thuong.
        task.defer(function()
            for _, child in ipairs(mainPage:GetChildren()) do
                if child:IsA("TextButton") and child.Text:find("Tele Kill", 1, true) then
                    child.Text = "  [OFF] Tele Kill"
                    child.BackgroundColor3 = Color3.fromRGB(43, 49, 63)
                end
            end
        end)
    end
end)
makeToggle(mainPage, "Hitbox All Mod", function(enabled)
    EspEngine:SetFeature("Esp Box", enabled)
end)
makeSlider(mainPage, "Scan Range", Config.ScanRange, 25, 500, function(v)
    Config.ScanRange = v
    TargetScanner:Scan(true)
end)
makeSlider(mainPage, "Safe Height", Config.SafeHeight, 3, 60, function(v)
    Config.SafeHeight = v
end)

-- ESP TAB
makeSection(espPage, "VISUAL TRACKING")
makeToggle(espPage, "Esp Line", function(enabled)
    EspEngine:SetFeature("Esp Line", enabled)
end)
makeToggle(espPage, "Esp Box", function(enabled)
    EspEngine:SetFeature("Esp Box", enabled)
end)
makeToggle(espPage, "Esp Name", function(enabled)
    EspEngine:SetFeature("Esp Name", enabled)
end)
makeToggle(espPage, "Esp Distance", function(enabled)
    EspEngine:SetFeature("Esp Distance", enabled)
end)
makeToggle(espPage, "Esp Hologram", function(enabled)
    EspEngine:SetFeature("Esp Hologram", enabled)
end)

-- OTHER TAB
makeSection(otherPage, "MOVEMENT")
makeToggle(otherPage, "Fly Air", function(enabled)
    if enabled then MovementAndWorld:StartFly()
    else MovementAndWorld:StopFly() end
end)
makeToggle(otherPage, "No Clip", function(enabled)
    MovementAndWorld:SetNoClip(enabled)
end)
makeToggle(otherPage, "Speed", function(enabled)
    MovementAndWorld:SetSpeed(enabled)
end)
makeToggle(otherPage, "Jumping Air", function(enabled)
    -- Xu ly trong JumpRequest ben duoi.
end)
makeToggle(otherPage, "Night Vision", function(enabled)
    MovementAndWorld:SetNightVision(enabled)
end)
makeToggle(otherPage, "Fix Lag", function(enabled)
    MovementAndWorld:SetFixLag(enabled)
end)
makeSlider(otherPage, "Fly Speed", Config.FlySpeed, 5, 150, function(v)
    Config.FlySpeed = v
end)
makeSlider(otherPage, "Walk Speed", Config.WalkSpeed, 8, 100, function(v)
    Config.WalkSpeed = v
    if StateManager:Get("Speed") then
        local _, hum = getRootAndHumanoid()
        if hum then hum.WalkSpeed = v end
    end
end)
makeSlider(otherPage, "Drone Height", Config.DroneHeightOffset, 1, 40, function(v)
    Config.DroneHeightOffset = v
    Config.SafeHeight = v
end)

showTab("Main")

--============================================================
-- DRAG WINDOW / MINIMIZE
--============================================================
local dragging = false
local dragStart, startPosition

Top.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPosition = Main.Position
    end
end)

Top.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        -- InputChanged is observed by global handler below.
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(
            startPosition.X.Scale, startPosition.X.Offset + delta.X,
            startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

local minimized = false
Minimize.MouseButton1Click:Connect(function()
    minimized = not minimized
    Content.Visible = not minimized
    Tabs.Visible = not minimized
    Main.Size = minimized and UDim2.fromOffset(340, 44)
        or UDim2.fromOffset(340, 440)
    Minimize.Text = minimized and "+" or "—"
end)

--============================================================
-- AIR JUMP
--============================================================
UserInputService.JumpRequest:Connect(function()
    if not StateManager:Get("Jumping Air") then return end
    local hum = getHumanoid(getCharacter())
    if hum and hum.Health > 0 then
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

--============================================================
-- CHARACTER RESPAWN SAFETY
--============================================================
local characterConnection
local function onCharacterAdded()
    MovementAndWorld:StopFly()
    CombatEngine:StopDrone()
    MovementAndWorld.NoClipSnapshot = {}
    if StateManager:Get("Speed") then
        task.defer(function()
            local hum = getHumanoid(getCharacter())
            if hum then
                StateManager.Snapshot.WalkSpeed = hum.WalkSpeed
                hum.WalkSpeed = Config.WalkSpeed
            end
        end)
    end
    if StateManager:Get("Fly Air") then
        task.delay(0.5, function()
            if StateManager:Get("Fly Air") then MovementAndWorld:StartFly() end
        end)
    end
end
characterConnection = LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

--============================================================
-- MAIN UPDATE LOOP
--============================================================
local updateConnection
updateConnection = RunService.RenderStepped:Connect(function()
    if not ScreenGui.Parent then
        updateConnection:Disconnect()
        return
    end

    TargetScanner:Scan(false)

    if StateManager:Get("Tele Dron") then
        CombatEngine:UpdateDrone()
    end

    if StateManager:Get("Aimbot") then
        CombatEngine:UpdateAim()
    end

    if StateManager:Get("Fly Air") then
        MovementAndWorld:UpdateFly()
    end

    EspEngine:Update()
end)

--============================================================
-- CLEANUP
--============================================================
local function cleanup()
    if updateConnection then updateConnection:Disconnect() end
    if characterConnection then characterConnection:Disconnect() end

    CombatEngine:StopDrone()
    MovementAndWorld:StopFly()
    EspEngine:CleanupAll()
    MovementAndWorld:SetNoClip(false)
    MovementAndWorld:SetNightVision(false)
    MovementAndWorld:SetFixLag(false)

    local _, hum = getRootAndHumanoid()
    local oldSpeed = StateManager:Restore("WalkSpeed")
    if hum and oldSpeed then hum.WalkSpeed = oldSpeed end

    safeDestroy(espFolder)
    safeDestroy(ScreenGui)
end

-- Nut dong menu an toan: nhan ESC de dong va khoi phuc.
local closeConnection
closeConnection = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.Escape then
        if closeConnection then closeConnection:Disconnect() end
        cleanup()
    end
end)

print("[DebugControl V1] Loaded successfully.")
print("[DebugControl V1] Press ESC to close and restore supported settings.")
