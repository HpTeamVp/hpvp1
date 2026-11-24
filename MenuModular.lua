--!strict
--[[
    DEBUG CONTROL V2 - SINGLE FILE
    Dành cho LocalScript trong Roblox Studio / game do bạn sở hữu.
    Không phải exploit/anti-cheat bypass. Không thể tự cấp quyền server.

    Những thao tác cần server authority (damage, sửa hitbox thật, khóa AI/NPC,
    chặn sát thương thật, xuyên tường gây damage) được để qua AttackHook /
    ServerDebugRemote do chủ game tự triển khai và kiểm tra quyền.
]]

--==============================================================
-- SERVICES
--==============================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--==============================================================
-- CONFIG / STATE MANAGER
--==============================================================
local StateManager = {}
StateManager.Config = {
    ScanRange = 150,
    ScanInterval = 0.35,
    DroneHeightOffset = 6,
    DroneFollowSpeed = 12,
    FlySpeed = 65,
    WalkSpeed = 32,
    SafeDistance = 7,
    AimSmoothness = 0.22,
    AimFovPixels = 300,
    EspLineThickness = 1,
    FixLagDisableParticles = true,
}
StateManager.Flags = {
    TeleDron = false, HitboxVisual = false, TeleKill = false,
    Aimbot = false, AllModInfo = false, ModelUnderground = false,
    ModelHeadDown = false, PlayerBarrierVisual = false,
    LongLegsVisual = false, LongHeadVisual = false,
    EspLine = false, EspBox = false, EspName = false,
    EspDistance = false, EspHologram = false,
    FlyDown = false, FlyDron = false, NoClip = false,
    FlyAir = false, Speed = false, JumpingAir = false,
    NightVision = false, FixLag = false,
}
StateManager.Snapshot = {
    Character = {}, Lighting = nil, Effects = {},
    NoClip = {}, WalkSpeed = nil, Gravity = nil,
}
function StateManager:Set(name, value)
    if self.Flags[name] == nil then return false end
    self.Flags[name] = value == true
    return true
end
function StateManager:Get(name)
    return self.Flags[name] == true
end
function StateManager:SetConfig(name, value)
    if self.Config[name] == nil or type(value) ~= "number" then return false end
    self.Config[name] = value
    return true
end

--==============================================================
-- SHARED HELPERS
--==============================================================
local function notify(message)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Debug Control V2", Text = tostring(message), Duration = 3
        })
    end)
end

local function getCharacter()
    local character = LocalPlayer.Character
    if not character then return nil, nil, nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    return character, humanoid, root
end

local function getModelRoot(model)
    if not model or not model:IsA("Model") then return nil end
    local root = model:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then return root end
    local primary = model.PrimaryPart
    if primary and primary:IsA("BasePart") then return primary end
    return nil
end

local function getHumanoid(model)
    return model and model:FindFirstChildOfClass("Humanoid") or nil
end

local function isValidNPC(model)
    if not model or not model:IsA("Model") then return false end
    if model == LocalPlayer.Character then return false end
    if Players:GetPlayerFromCharacter(model) then return false end
    local humanoid = getHumanoid(model)
    local root = getModelRoot(model)
    return humanoid ~= nil and humanoid.Health > 0 and root ~= nil and model:IsDescendantOf(Workspace)
end

local function distanceTo(model)
    local _, _, root = getCharacter()
    local targetRoot = getModelRoot(model)
    if not root or not targetRoot then return math.huge end
    return (root.Position - targetRoot.Position).Magnitude
end

--==============================================================
-- TARGET SCANNER
--==============================================================
local TargetScanner = {
    Cache = {},
    LastScan = 0,
}
function TargetScanner:Scan(force)
    local cfg = StateManager.Config
    if not force and os.clock() - self.LastScan < cfg.ScanInterval then
        return self.Cache
    end
    self.LastScan = os.clock()
    table.clear(self.Cache)

    local _, _, localRoot = getCharacter()
    if not localRoot then return self.Cache end

    -- Quét theo chu kỳ, không quét toàn Workspace mỗi frame.
    for _, instance in ipairs(Workspace:GetDescendants()) do
        if instance:IsA("Model") and isValidNPC(instance) then
            local root = getModelRoot(instance)
            local dist = root and (root.Position - localRoot.Position).Magnitude or math.huge
            if dist <= cfg.ScanRange then
                table.insert(self.Cache, {Model = instance, Distance = dist})
            end
        end
    end

    table.sort(self.Cache, function(a, b)
        return a.Distance < b.Distance
    end)
    return self.Cache
end

function TargetScanner:GetNearest()
    local list = self:Scan(false)
    for _, entry in ipairs(list) do
        if isValidNPC(entry.Model) and entry.Distance <= StateManager.Config.ScanRange then
            return entry.Model
        end
    end
    return nil
end

function TargetScanner:IsInRange(model)
    return isValidNPC(model) and distanceTo(model) <= StateManager.Config.ScanRange
end

--==============================================================
-- ATTACK HOOK
--==============================================================
local CombatEngine = {
    LockedTarget = nil,
    LastAttackAt = 0,
    AttackCooldown = 0.25,
}
-- Gắn RemoteEvent/weapon logic của GAME BẠN tại đây.
-- Server phải tự xác thực người chơi, khoảng cách, cooldown, line-of-sight,
-- trạng thái mục tiêu và quyền debug. Không tin target/mode do client gửi.
function CombatEngine:AttackHook(target, mode)
    if not TargetScanner:IsInRange(target) then return false, "Target invalid/out of range" end
    if os.clock() - self.LastAttackAt < self.AttackCooldown then
        return false, "Cooldown"
    end
    self.LastAttackAt = os.clock()

    -- Ví dụ tích hợp an toàn:
    -- local remote = game.ReplicatedStorage:FindFirstChild("DebugAttackRequest")
    -- if remote and remote:IsA("RemoteEvent") then
    --     remote:FireServer(target, mode) -- server bắt buộc kiểm tra lại mọi điều kiện
    -- end
    return false, "Chưa cấu hình AttackHook phía server"
end

function CombatEngine:GetLockedTarget()
    if self.LockedTarget and TargetScanner:IsInRange(self.LockedTarget) then
        return self.LockedTarget
    end
    self.LockedTarget = TargetScanner:GetNearest()
    return self.LockedTarget
end

function CombatEngine:TeleportNearTarget()
    local _, _, root = getCharacter()
    local target = self:GetLockedTarget()
    local targetRoot = getModelRoot(target)
    if not root or not targetRoot then return end
    local safe = StateManager.Config.SafeDistance
    local offset = targetRoot.CFrame.LookVector * safe
    root.CFrame = CFrame.lookAt(targetRoot.Position + offset, targetRoot.Position)
end

function CombatEngine:UpdateTeleDron(dt)
    if not StateManager:Get("TeleDron") then return end
    local _, humanoid, root = getCharacter()
    local target = self:GetLockedTarget()
    local targetRoot = getModelRoot(target)
    if not humanoid or not root or not targetRoot then return end

    local destination = targetRoot.Position + Vector3.new(0, StateManager.Config.DroneHeightOffset, 0)
    local alpha = math.clamp(dt * StateManager.Config.DroneFollowSpeed, 0, 1)
    local nextPosition = root.Position:Lerp(destination, alpha)
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.lookAt(nextPosition, targetRoot.Position)
    -- Chỉ gọi hook nếu chủ game đã cài đặt logic attack server.
    self:AttackHook(target, "TeleDron")
end

function CombatEngine:UpdateAimbot(dt)
    if not StateManager:Get("Aimbot") then return end
    local camera = Workspace.CurrentCamera
    local target = self:GetLockedTarget()
    local targetRoot = target and (target:FindFirstChild("Head") or getModelRoot(target))
    if not camera or not targetRoot then return end

    local screenPoint, visible = camera:WorldToViewportPoint(targetRoot.Position)
    if not visible or screenPoint.Z <= 0 then return end
    local center = camera.ViewportSize / 2
    local screenDistance = (Vector2.new(screenPoint.X, screenPoint.Y) - center).Magnitude
    if screenDistance > StateManager.Config.AimFovPixels then return end

    local goal = CFrame.lookAt(camera.CFrame.Position, targetRoot.Position)
    local smooth = math.clamp(StateManager.Config.AimSmoothness * dt * 60, 0, 1)
    camera.CFrame = camera.CFrame:Lerp(goal, smooth)
end

function CombatEngine:UpdateTeleKill()
    if not StateManager:Get("TeleKill") then return end
    StateManager:Set("TeleKill", false) -- hành động một lần, tránh spam vòng lặp
    local target = self:GetLockedTarget()
    if not target then notify("Không có NPC hợp lệ trong phạm vi."); return end
    self:TeleportNearTarget()
    local ok, reason = self:AttackHook(target, "TeleKill")
    if not ok then notify("Đã tới gần mục tiêu. AttackHook: " .. tostring(reason)) end
end

--==============================================================
-- ESP ENGINE
--==============================================================
local EspEngine = {
    Gui = nil,
    Objects = {},
}
function EspEngine:Init(parent)
    if self.Gui and self.Gui.Parent then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = "DebugControlV2_ESP"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 998
    gui.Parent = parent
    self.Gui = gui
end

function EspEngine:Create(model)
    if self.Objects[model] then return self.Objects[model] end
    local holder = Instance.new("Frame")
    holder.Name = "ESP_" .. model.Name
    holder.BackgroundTransparency = 1
    holder.Size = UDim2.fromOffset(40, 60)
    holder.Visible = false
    holder.Parent = self.Gui

    local box = Instance.new("Frame")
    box.BackgroundTransparency = 1
    box.BorderSizePixel = 1
    box.BorderColor3 = Color3.fromRGB(40, 230, 130)
    box.Size = UDim2.fromScale(1, 1)
    box.Parent = holder

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.Size = UDim2.new(0, 190, 0, 18)
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 12
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.TextStrokeTransparency = 0.2
    nameLabel.Parent = holder

    local distanceLabel = Instance.new("TextLabel")
    distanceLabel.BackgroundTransparency = 1
    distanceLabel.Position = UDim2.fromOffset(0, 18)
    distanceLabel.Size = UDim2.new(0, 190, 0, 16)
    distanceLabel.Font = Enum.Font.Gotham
    distanceLabel.TextSize = 10
    distanceLabel.TextColor3 = Color3.fromRGB(120, 220, 255)
    distanceLabel.TextStrokeTransparency = 0.2
    distanceLabel.Parent = holder

    local line = Instance.new("Frame")
    line.AnchorPoint = Vector2.new(0.5, 0.5)
    line.BorderSizePixel = 0
    line.BackgroundColor3 = Color3.fromRGB(255, 220, 70)
    line.Parent = self.Gui

    local highlight = Instance.new("Highlight")
    highlight.Name = "DC2_ESP_Highlight"
    highlight.Adornee = model
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = Color3.fromRGB(55, 170, 255)
    highlight.OutlineColor = Color3.fromRGB(120, 220, 255)
    highlight.FillTransparency = 0.82
    highlight.Enabled = false
    highlight.Parent = model

    local data = {Holder = holder, Box = box, Name = nameLabel, Distance = distanceLabel,
        Line = line, Highlight = highlight}
    self.Objects[model] = data
    return data
end

function EspEngine:Cleanup(model)
    local data = self.Objects[model]
    if not data then return end
    for _, object in pairs(data) do
        if typeof(object) == "Instance" then
            pcall(function() object:Destroy() end)
        end
    end
    self.Objects[model] = nil
end

function EspEngine:CleanupAll()
    for model in pairs(self.Objects) do self:Cleanup(model) end
end

local function getProjectedBounds(camera, model)
    local ok, cf, size = pcall(function()
        return model:GetBoundingBox()
    end)
    if not ok then return nil end
    local corners = {}
    local half = size / 2
    for x = -1, 1, 2 do
        for y = -1, 1, 2 do
            for z = -1, 1, 2 do
                local world = cf:PointToWorldSpace(Vector3.new(half.X*x, half.Y*y, half.Z*z))
                local point, visible = camera:WorldToViewportPoint(world)
                if point.Z > 0 then
                    table.insert(corners, Vector2.new(point.X, point.Y))
                end
            end
        end
    end
    if #corners == 0 then return nil end
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(corners) do
        minX, minY = math.min(minX, p.X), math.min(minY, p.Y)
        maxX, maxY = math.max(maxX, p.X), math.max(maxY, p.Y)
    end
    return minX, minY, maxX - minX, maxY - minY
end

function EspEngine:Update()
    local flags = StateManager.Flags
    local active = flags.EspLine or flags.EspBox or flags.EspName or flags.EspDistance or flags.EspHologram
        or flags.HitboxVisual or flags.AllModInfo
    if not active then self:CleanupAll(); return end

    local camera = Workspace.CurrentCamera
    if not camera then return end
    local valid = {}

    for _, entry in ipairs(TargetScanner:Scan(false)) do
        local model = entry.Model
        if isValidNPC(model) and entry.Distance <= StateManager.Config.ScanRange then
            valid[model] = true
            local data = self:Create(model)
            local x, y, w, h = getProjectedBounds(camera, model)
            local onScreen = x ~= nil
            data.Holder.Visible = onScreen
            if onScreen then
                data.Holder.Position = UDim2.fromOffset(x, y)
                data.Holder.Size = UDim2.fromOffset(math.max(w, 2), math.max(h, 2))
            end
            data.Box.Visible = onScreen and (flags.EspBox or flags.HitboxVisual)
            data.Name.Visible = onScreen and (flags.EspName or flags.AllModInfo)
            data.Name.Position = UDim2.fromOffset(0, -18)
            data.Name.Text = model.Name
            data.Distance.Visible = onScreen and (flags.EspDistance or flags.AllModInfo)
            data.Distance.Position = UDim2.fromOffset(0, h + 1)
            data.Distance.Text = string.format("%.1f studs", entry.Distance)
            data.Highlight.Enabled = flags.EspHologram
            data.Line.Visible = onScreen and flags.EspLine
            if data.Line.Visible then
                local center = Vector2.new(camera.ViewportSize.X / 2, 0)
                local target = Vector2.new(x + w/2, y)
                local delta = target - center
                data.Line.Position = UDim2.fromOffset(center.X + delta.X/2, center.Y + delta.Y/2)
                data.Line.Size = UDim2.fromOffset(delta.Magnitude, StateManager.Config.EspLineThickness)
                data.Line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
            end
        end
    end

    for model in pairs(self.Objects) do
        if not valid[model] or not model.Parent then self:Cleanup(model) end
    end
end

--==============================================================
-- MOVEMENT AND WORLD
--==============================================================
local MovementAndWorld = {
    FlightVelocity = nil,
    FlightGyro = nil,
    JumpConnection = nil,
}
function MovementAndWorld:StartFlight()
    local _, humanoid, root = getCharacter()
    if not humanoid or not root then return end
    self:StopFlight()
    local velocity = Instance.new("BodyVelocity")
    velocity.Name = "DC2_FlightVelocity"
    velocity.MaxForce = Vector3.new(1e6, 1e6, 1e6)
    velocity.Velocity = Vector3.zero
    velocity.Parent = root
    local gyro = Instance.new("BodyGyro")
    gyro.Name = "DC2_FlightGyro"
    gyro.MaxTorque = Vector3.new(1e6, 1e6, 1e6)
    gyro.P = 8000
    gyro.CFrame = Workspace.CurrentCamera.CFrame
    gyro.Parent = root
    self.FlightVelocity, self.FlightGyro = velocity, gyro
    humanoid.PlatformStand = true
end

function MovementAndWorld:StopFlight()
    if self.FlightVelocity then self.FlightVelocity:Destroy(); self.FlightVelocity = nil end
    if self.FlightGyro then self.FlightGyro:Destroy(); self.FlightGyro = nil end
    local _, humanoid = getCharacter()
    if humanoid then humanoid.PlatformStand = false end
end

function MovementAndWorld:UpdateFlight()
    if not StateManager:Get("FlyAir") then
        if self.FlightVelocity or self.FlightGyro then self:StopFlight() end
        return
    end
    local _, humanoid, root = getCharacter()
    if not humanoid or not root then self:StopFlight(); return end
    if not self.FlightVelocity or self.FlightVelocity.Parent ~= root then self:StartFlight() end
    local camera = Workspace.CurrentCamera
    if not self.FlightVelocity or not camera then return end

    local direction = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction += camera.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction -= camera.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction -= camera.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction += camera.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction += Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or StateManager:Get("FlyDown") then
        direction -= Vector3.yAxis
    end
    if direction.Magnitude > 0 then direction = direction.Unit end
    self.FlightVelocity.Velocity = direction * StateManager.Config.FlySpeed
    self.FlightGyro.CFrame = camera.CFrame
end

function MovementAndWorld:UpdateNoClip()
    local character = LocalPlayer.Character
    if not character then return end
    if StateManager:Get("NoClip") then
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                if StateManager.Snapshot.NoClip[part] == nil then
                    StateManager.Snapshot.NoClip[part] = part.CanCollide
                end
                part.CanCollide = false
            end
        end
    else
        for part, old in pairs(StateManager.Snapshot.NoClip) do
            if part and part.Parent then part.CanCollide = old end
        end
        table.clear(StateManager.Snapshot.NoClip)
    end
end

function MovementAndWorld:UpdateSpeed()
    local _, humanoid = getCharacter()
    if not humanoid then return end
    if StateManager:Get("Speed") then
        if StateManager.Snapshot.WalkSpeed == nil then
            StateManager.Snapshot.WalkSpeed = humanoid.WalkSpeed
        end
        humanoid.WalkSpeed = StateManager.Config.WalkSpeed
    elseif StateManager.Snapshot.WalkSpeed ~= nil then
        humanoid.WalkSpeed = StateManager.Snapshot.WalkSpeed
        StateManager.Snapshot.WalkSpeed = nil
    end
end

function MovementAndWorld:UpdateDrone(dt)
    if not StateManager:Get("FlyDron") then return end
    local _, _, root = getCharacter()
    local target = CombatEngine:GetLockedTarget()
    local targetRoot = getModelRoot(target)
    if not root or not targetRoot then return end
    local destination = targetRoot.Position + Vector3.new(0, StateManager.Config.DroneHeightOffset, 0)
    local delta = destination - root.Position
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.lookAt(root.Position + delta * math.clamp((dt or 0) * 1.5, 0, 1), targetRoot.Position)
end

function MovementAndWorld:SetNightVision(enabled)
    local snapshot = StateManager.Snapshot
    if enabled then
        if not snapshot.Lighting then
            snapshot.Lighting = {
                Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
                Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
                FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
            }
        end
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.Ambient = Color3.fromRGB(180, 200, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(170, 190, 170)
        Lighting.FogEnd = 100000
        Lighting.GlobalShadows = false
    elseif snapshot.Lighting then
        for property, value in pairs(snapshot.Lighting) do
            pcall(function() Lighting[property] = value end)
        end
        snapshot.Lighting = nil
    end
end

function MovementAndWorld:SetFixLag(enabled)
    local saved = StateManager.Snapshot.Effects
    if enabled then
        for _, item in ipairs(Workspace:GetDescendants()) do
            if item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam") then
                if saved[item] == nil then saved[item] = item.Enabled end
                item.Enabled = false
            end
        end
    else
        for item, old in pairs(saved) do
            if item and item.Parent then item.Enabled = old end
        end
        table.clear(saved)
    end
end

function MovementAndWorld:UpdateJumpingAir()
    local _, humanoid = getCharacter()
    if StateManager:Get("JumpingAir") and humanoid and UserInputService:IsKeyDown(Enum.KeyCode.Space) then
        if humanoid.FloorMaterial == Enum.Material.Air then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end

--==============================================================
-- UI CONTROLLER
--==============================================================
local UIController = {
    Gui = nil,
    Main = nil,
    Content = nil,
    Status = nil,
    Connections = {},
    Minimized = false,
}
function UIController:Connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(self.Connections, connection)
    return connection
end
function UIController:ClearConnections()
    for _, connection in ipairs(self.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(self.Connections)
end

local function create(className, properties, parent)
    local obj = Instance.new(className)
    for key, value in pairs(properties or {}) do obj[key] = value end
    obj.Parent = parent
    return obj
end

function UIController:Init()
    local old = PlayerGui:FindFirstChild("DebugControlV2")
    if old then old:Destroy() end

    local gui = create("ScreenGui", {
        Name = "DebugControlV2", ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 1000
    }, PlayerGui)
    self.Gui = gui

    local main = create("Frame", {
        Name = "Window", Size = UDim2.fromOffset(560, 440),
        Position = UDim2.new(0.5, -280, 0.5, -220),
        BackgroundColor3 = Color3.fromRGB(17, 22, 32), BorderSizePixel = 0
    }, gui)
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(65, 125, 190)
    self.Main = main

    local top = create("Frame", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = Color3.fromRGB(26, 37, 53), BorderSizePixel = 0
    }, main)
    Instance.new("UICorner", top).CornerRadius = UDim.new(0, 10)
    create("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(13, 0),
        Size = UDim2.new(1, -105, 1, 0), Font = Enum.Font.GothamBold,
        Text = "DEBUG CONTROL V2", TextColor3 = Color3.fromRGB(240, 245, 255),
        TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left
    }, top)

    local minButton = create("TextButton", {
        Position = UDim2.new(1, -76, 0, 8), Size = UDim2.fromOffset(30, 28),
        Text = "—", Font = Enum.Font.GothamBold, TextSize = 18,
        TextColor3 = Color3.new(1,1,1), BackgroundColor3 = Color3.fromRGB(54,72,95)
    }, top)
    local closeButton = create("TextButton", {
        Position = UDim2.new(1, -39, 0, 8), Size = UDim2.fromOffset(30, 28),
        Text = "×", Font = Enum.Font.GothamBold, TextSize = 20,
        TextColor3 = Color3.new(1,1,1), BackgroundColor3 = Color3.fromRGB(130,55,60)
    }, top)
    for _, b in ipairs({minButton, closeButton}) do
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    end

    local tabs = create("Frame", {
        Position = UDim2.fromOffset(10, 54), Size = UDim2.new(0, 125, 1, -88),
        BackgroundColor3 = Color3.fromRGB(23, 31, 44), BorderSizePixel = 0
    }, main)
    Instance.new("UICorner", tabs).CornerRadius = UDim.new(0, 8)

    local content = create("ScrollingFrame", {
        Position = UDim2.fromOffset(145, 54), Size = UDim2.new(1, -155, 1, -86),
        BackgroundColor3 = Color3.fromRGB(22, 29, 42), BorderSizePixel = 0,
        ScrollBarThickness = 4, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y
    }, main)
    Instance.new("UICorner", content).CornerRadius = UDim.new(0, 8)
    self.Content = content

    local status = create("TextLabel", {
        Position = UDim2.new(0, 145, 1, -26), Size = UDim2.new(1, -155, 0, 18),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
        Text = "Ready | NPC only | Range 150 studs",
        TextColor3 = Color3.fromRGB(145, 180, 210), TextXAlignment = Enum.TextXAlignment.Left
    }, main)
    self.Status = status

    -- Kéo cửa sổ bằng thanh tiêu đề.
    local dragging, dragInput, dragStart, startPosition
    self:Connect(top.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPosition = true, input.Position, main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    self:Connect(top.InputChanged, function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    self:Connect(UserInputService.InputChanged, function(input)
        if dragging and input == dragInput then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end)

    self:Connect(minButton.MouseButton1Click, function()
        self.Minimized = not self.Minimized
        tabs.Visible = not self.Minimized
        content.Visible = not self.Minimized
        status.Visible = not self.Minimized
        main.Size = self.Minimized and UDim2.fromOffset(560, 44) or UDim2.fromOffset(560, 440)
        minButton.Text = self.Minimized and "+" or "—"
    end)
    self:Connect(closeButton.MouseButton1Click, function()
        self:Destroy()
    end)

    self.TabButtons = {}
    local function setStatus(text)
        status.Text = text
    end
    self.SetStatus = setStatus
    for index, tabName in ipairs({"Main", "Esp", "Khác"}) do
        local button = create("TextButton", {
            Position = UDim2.fromOffset(7, 9 + (index - 1) * 43),
            Size = UDim2.new(1, -14, 0, 34), Text = tabName,
            Font = Enum.Font.GothamBold, TextSize = 12,
            TextColor3 = Color3.new(1,1,1), BackgroundColor3 = Color3.fromRGB(35,48,67)
        }, tabs)
        Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
        self.TabButtons[tabName] = button
    end

    self:BuildTab("Main")
end

function UIController:ClearContent()
    for _, child in ipairs(self.Content:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end
end

function UIController:AddSection(text)
    create("TextLabel", {
        Size = UDim2.new(1, -16, 0, 24), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, Text = text, TextSize = 12,
        TextColor3 = Color3.fromRGB(105, 175, 240), TextXAlignment = Enum.TextXAlignment.Left
    }, self.Content)
end

function UIController:AddToggle(key, label, description, action)
    local row = create("Frame", {
        Size = UDim2.new(1, -16, 0, 45), BackgroundColor3 = Color3.fromRGB(32,42,58),
        BorderSizePixel = 0
    }, self.Content)
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
    create("TextLabel", {
        Position = UDim2.fromOffset(9, 3), Size = UDim2.new(1, -100, 0, 19),
        BackgroundTransparency = 1, Font = Enum.Font.GothamSemibold,
        Text = label, TextSize = 11, TextColor3 = Color3.fromRGB(240,244,250),
        TextXAlignment = Enum.TextXAlignment.Left
    }, row)
    create("TextLabel", {
        Position = UDim2.fromOffset(9, 22), Size = UDim2.new(1, -100, 0, 16),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham,
        Text = description or "", TextSize = 9, TextColor3 = Color3.fromRGB(150,165,185),
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd
    }, row)
    local button = create("TextButton", {
        Position = UDim2.new(1, -72, 0.5, -12), Size = UDim2.fromOffset(62, 24),
        Font = Enum.Font.GothamBold, TextSize = 10,
        Text = StateManager:Get(key) and "ON" or "OFF",
        TextColor3 = Color3.new(1,1,1),
        BackgroundColor3 = StateManager:Get(key) and Color3.fromRGB(35,145,95) or Color3.fromRGB(75,83,98)
    }, row)
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
    self:Connect(button.MouseButton1Click, function()
        local value = not StateManager:Get(key)
        StateManager:Set(key, value)
        button.Text = value and "ON" or "OFF"
        button.BackgroundColor3 = value and Color3.fromRGB(35,145,95) or Color3.fromRGB(75,83,98)
        if action then action(value) end
        if key == "TeleKill" and value then
            task.defer(function()
                CombatEngine:UpdateTeleKill()
                button.Text = "OFF"
                button.BackgroundColor3 = Color3.fromRGB(75,83,98)
            end)
        end
        if self.SetStatus then self.SetStatus(label .. (value and " ON" or " OFF")) end
    end)
end

function UIController:AddSlider(title, configKey, minimum, maximum)
    local row = create("Frame", {
        Size = UDim2.new(1, -16, 0, 55), BackgroundColor3 = Color3.fromRGB(32,42,58),
        BorderSizePixel = 0
    }, self.Content)
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
    local value = StateManager.Config[configKey]
    local label = create("TextLabel", {
        Position = UDim2.fromOffset(9, 3), Size = UDim2.new(1, -18, 0, 18),
        BackgroundTransparency = 1, Font = Enum.Font.GothamSemibold,
        Text = title .. ": " .. tostring(value), TextSize = 11,
        TextColor3 = Color3.fromRGB(240,244,250), TextXAlignment = Enum.TextXAlignment.Left
    }, row)
    local bar = create("Frame", {
        Position = UDim2.fromOffset(9, 31), Size = UDim2.new(1, -18, 0, 8),
        BackgroundColor3 = Color3.fromRGB(58,70,90), BorderSizePixel = 0
    }, row)
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1,0)
    local fill = create("Frame", {
        Size = UDim2.new((value-minimum)/(maximum-minimum), 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(65,150,225), BorderSizePixel = 0
    }, bar)
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1,0)

    local active = false
    local function update(input)
        local x = math.clamp((input.Position.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        local v = math.floor(minimum + (maximum-minimum)*x)
        StateManager:SetConfig(configKey, v)
        label.Text = title .. ": " .. tostring(v)
        fill.Size = UDim2.new(x,0,1,0)
    end
    self:Connect(bar.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            active = true
            update(input)
        end
    end)
    self:Connect(UserInputService.InputChanged, function(input)
        if active and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            update(input)
        end
    end)
    self:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            active = false
        end
    end)
end

function UIController:BuildTab(tabName)
    self:ClearContent()
    local layout = create("UIListLayout", {
        Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder
    }, self.Content)
    create("UIPadding", {
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8)
    }, self.Content)

    if tabName == "Main" then
        self:AddSection("COMBAT / TARGET")
        self:AddToggle("TeleDron", "Tele Dron", "Giữ vị trí trên NPC; client-side")
        self:AddToggle("HitboxVisual", "Hitbox All Mod", "Bounding-box chẩn đoán; không sửa hitbox server")
        self:AddToggle("TeleKill", "Tele Kill", "Một lần dịch chuyển; attack cần server hook")
        self:AddToggle("Aimbot", "Aimbot", "Khóa camera vào NPC gần nhất")
        self:AddToggle("AllModInfo", "All Mod Im", "Hiện thông tin NPC")
        self:AddSection("MODEL / BARRIER VISUAL TEST")
        self:AddToggle("ModelUnderground", "Model Độn Thổ", "Chưa triển khai điều khiển AI server")
        self:AddToggle("ModelHeadDown", "Model head down", "Chưa triển khai điều khiển rig NPC server")
        self:AddToggle("PlayerBarrierVisual", "Player Barrier", "Chỉ là hiệu ứng trực quan")
        self:AddToggle("LongLegsVisual", "Long Legs", "Chỉ hiển thị chẩn đoán; không sửa NPC")
        self:AddToggle("LongHeadVisual", "Long head", "Chỉ hiển thị chẩn đoán; không sửa NPC")
        self:AddSlider("Safe distance", "SafeDistance", 3, 25)
        self:AddSlider("Drone height", "DroneHeightOffset", 2, 30)
        self:AddSlider("Aim FOV", "AimFovPixels", 50, 700)
    elseif tabName == "Esp" then
        self:AddSection("NPC ESP | SCAN RANGE 150")
        self:AddToggle("EspLine", "Esp Line", "Đường từ mép trên giữa màn hình")
        self:AddToggle("EspBox", "Esp Box", "Khung theo bounding box 3D chiếu 2D")
        self:AddToggle("EspName", "Esp Name", "Tên NPC")
        self:AddToggle("EspDistance", "Esp Distance", "Khoảng cách studs")
        self:AddToggle("EspHologram", "Esp Hologram", "Highlight xuyên vật cản")
        self:AddSlider("Scan range", "ScanRange", 25, 500)
    else
        self:AddSection("MOVEMENT")
        self:AddToggle("FlyDown", "Fly Down", "Giảm độ cao khi bật Fly Air")
        self:AddToggle("FlyDron", "Fly Dron", "Theo NPC ở độ cao Drone")
        self:AddToggle("NoClip", "No Clip", "Tắt va chạm local; tự khôi phục")
        self:AddToggle("FlyAir", "Fly Air", "WASD, Space lên, Ctrl xuống")
        self:AddToggle("Speed", "Speed", "WalkSpeed local")
        self:AddToggle("JumpingAir", "Jumping Air", "Nhảy lại khi giữ Space trên không")
        self:AddSection("WORLD")
        self:AddToggle("NightVision", "Night Vision", "Lưu và khôi phục ánh sáng")
        self:AddToggle("FixLag", "Fix Lag", "Tắt particle/trail/beam local")
        self:AddSlider("Fly speed", "FlySpeed", 20, 180)
        self:AddSlider("Walk speed", "WalkSpeed", 16, 150)
    end

    for name, button in pairs(self.TabButtons) do
        button.BackgroundColor3 = name == tabName and Color3.fromRGB(48,105,160) or Color3.fromRGB(35,48,67)
        if not button:GetAttribute("DC2Bound") then
            button:SetAttribute("DC2Bound", true)
            self:Connect(button.MouseButton1Click, function() self:BuildTab(name) end)
        end
    end
end

function UIController:Destroy()
    self:ClearConnections()
    if self.Gui then self.Gui:Destroy(); self.Gui = nil end
    StateManager:Set("FlyAir", false)
    StateManager:Set("NoClip", false)
    StateManager:Set("Speed", false)
    StateManager:Set("NightVision", false)
    StateManager:Set("FixLag", false)
    MovementAndWorld:StopFlight()
    MovementAndWorld:UpdateNoClip()
    MovementAndWorld:UpdateSpeed()
    MovementAndWorld:SetNightVision(false)
    MovementAndWorld:SetFixLag(false)
    EspEngine:CleanupAll()
    if EspEngine.Gui then EspEngine.Gui:Destroy(); EspEngine.Gui = nil end
end

--==============================================================
-- STATE TRANSITIONS / RUNTIME
--==============================================================
local Previous = {}
local function processTransitions()
    for key, enabled in pairs(StateManager.Flags) do
        if Previous[key] ~= enabled then
            Previous[key] = enabled
            if key == "NightVision" then MovementAndWorld:SetNightVision(enabled) end
            if key == "FixLag" then MovementAndWorld:SetFixLag(enabled) end
            if key == "FlyAir" and not enabled then MovementAndWorld:StopFlight() end
            if key == "PlayerBarrierVisual" then
                -- Visual-only ring around local player. No damage protection.
                local character = LocalPlayer.Character
                if enabled and character and not character:FindFirstChild("DC2_BarrierVisual") then
                    local ring = Instance.new("Part")
                    ring.Name = "DC2_BarrierVisual"
                    ring.Shape = Enum.PartType.Cylinder
                    ring.Size = Vector3.new(0.15, 12, 12)
                    ring.Transparency = 0.72
                    ring.Color = Color3.fromRGB(50, 180, 255)
                    ring.Material = Enum.Material.ForceField
                    ring.CanCollide = false
                    ring.Anchored = false
                    ring.Massless = true
                    ring.Parent = character
                    local root = character:FindFirstChild("HumanoidRootPart")
                    if root then
                        ring.CFrame = root.CFrame * CFrame.Angles(0, 0, math.rad(90))
                        local weld = Instance.new("WeldConstraint")
                        weld.Part0, weld.Part1 = root, ring
                        weld.Parent = ring
                    end
                elseif not enabled and character then
                    local ring = character:FindFirstChild("DC2_BarrierVisual")
                    if ring then ring:Destroy() end
                end
            end
        end
    end
end

--==============================================================
-- CHARACTER RESPAWN / CLEANUP
--==============================================================
local RuntimeConnections = {}
local function runtimeConnect(signal, callback)
    local c = signal:Connect(callback)
    table.insert(RuntimeConnections, c)
    return c
end

runtimeConnect(LocalPlayer.CharacterAdded, function()
    task.wait(0.35)
    StateManager.Snapshot.WalkSpeed = nil
    table.clear(StateManager.Snapshot.NoClip)
    if StateManager:Get("FlyAir") then MovementAndWorld:StartFlight() end
end)

runtimeConnect(LocalPlayer.CharacterRemoving, function()
    MovementAndWorld:StopFlight()
    table.clear(StateManager.Snapshot.NoClip)
end)

runtimeConnect(UserInputService.JumpRequest, function()
    if StateManager:Get("JumpingAir") then
        local _, humanoid = getCharacter()
        if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end)

--==============================================================
-- START
--==============================================================
UIController:Init()
EspEngine:Init(UIController.Gui)

local destroyed = false
runtimeConnect(RunService.Heartbeat, function(dt)
    if destroyed or not UIController.Gui or not UIController.Gui.Parent then
        destroyed = true
        return
    end
    processTransitions()
    MovementAndWorld:UpdateFlight()
    MovementAndWorld:UpdateNoClip()
    MovementAndWorld:UpdateSpeed()
    MovementAndWorld:UpdateJumpingAir()
    CombatEngine:UpdateTeleDron(dt)
    CombatEngine:UpdateAimbot(dt)
    MovementAndWorld:UpdateDrone(dt)
    EspEngine:Update()
end)

-- Xóa kết nối runtime khi GUI bị đóng.
local originalDestroy = UIController.Destroy
function UIController:Destroy()
    if destroyed then return end
    destroyed = true
    originalDestroy(self)
    for _, connection in ipairs(RuntimeConnections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(RuntimeConnections)
end

notify("Debug Control V2 đã khởi chạy.")
