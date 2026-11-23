--[[
    ModularControlMenu.lua
    Bộ công cụ Debug & QA Testing nội bộ (chỉ chạy cho chủ game / Studio).
    Modules: StateManager, TargetScanner, CombatEngine, EspEngine, MovementAndWorld, UIController
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------
-- OWNER GATE
----------------------------------------------------------------------
local function IsOwner()
    if RunService:IsStudio() then
        return true
    end
    if game.CreatorType == Enum.CreatorType.Group then
        local ok, rank = pcall(function()
            return LocalPlayer:GetRankInGroup(game.CreatorId)
        end)
        return ok and rank >= 255
    end
    return LocalPlayer.UserId == game.CreatorId
end

if not IsOwner() then
    return
end

local globalEnv = (getgenv and getgenv()) or _G
if globalEnv.__ModularControlMenu and globalEnv.__ModularControlMenu.Shutdown then
    pcall(globalEnv.__ModularControlMenu.Shutdown)
end

----------------------------------------------------------------------
-- SHARED HELPERS
----------------------------------------------------------------------
local Connections = {}
local function Track(conn)
    table.insert(Connections, conn)
    return conn
end

local function GetCharacter()
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return char, hum, hrp
end

local function GetGuiParent()
    local ok, result = pcall(function()
        if gethui then return gethui() end
        return game:GetService("CoreGui")
    end)
    if ok and result then
        return result
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function GetModelRoot(model)
    return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function GetAimPosition(model)
    local head = model:FindFirstChild("Head")
    if head and head:IsA("BasePart") then
        return head.Position
    end
    local root = GetModelRoot(model)
    return root and root.Position or model:GetPivot().Position
end

----------------------------------------------------------------------
-- StateManager
----------------------------------------------------------------------
local StateManager = {}
StateManager.Config = {
    ScanRange = 150,
    DroneHeightOffset = 12,
    FlySpeed = 60,
    WalkSpeed = 40,
    FireInterval = 0.15,
    KillOffset = 4,
    AimSmoothness = 0.25,
    HitboxSize = 20,       -- kích thước hitbox mở rộng (studs, mỗi cạnh)
    FlyDronHeight = 6,     -- độ cao giữ cố định so với mặt đất (mặc định 6)
    FlyDownDepth = 8,      -- độ sâu hạ xuống dưới mặt đất khi bật Fly Down
    FlyAdjustRate = 12,    -- tốc độ tăng/giảm độ cao (studs/giây) khi giữ nút
}
StateManager.Flags = {}
StateManager.Snapshot = {}

local flagListeners = {}
local anyListeners = {}
local exclusiveGroup = {
    TeleDron = "Position", TeleKill = "Position",
    FlyAir = "Position", FlyDown = "Position", FlyDron = "Position",
}

function StateManager.OnChanged(name, fn)
    flagListeners[name] = flagListeners[name] or {}
    table.insert(flagListeners[name], fn)
end

function StateManager.OnAnyChanged(fn)
    table.insert(anyListeners, fn)
end

function StateManager.Get(name)
    return StateManager.Flags[name] == true
end

function StateManager.Set(name, value)
    value = value and true or false
    if StateManager.Flags[name] == value then return end

    if value and exclusiveGroup[name] then
        for other, group in pairs(exclusiveGroup) do
            if other ~= name and group == exclusiveGroup[name] and StateManager.Flags[other] then
                StateManager.Set(other, false)
            end
        end
    end

    StateManager.Flags[name] = value
    for _, fn in ipairs(flagListeners[name] or {}) do
        task.spawn(fn, value)
    end
    for _, fn in ipairs(anyListeners) do
        task.spawn(fn, name, value)
    end
end

function StateManager.Toggle(name)
    StateManager.Set(name, not StateManager.Flags[name])
end

function StateManager.SetConfig(key, value, minV, maxV)
    if type(value) ~= "number" then return StateManager.Config[key] end
    if minV then value = math.max(minV, value) end
    if maxV then value = math.min(maxV, value) end
    StateManager.Config[key] = value
    return value
end

function StateManager.AnyEnabled(names)
    for _, n in ipairs(names) do
        if StateManager.Flags[n] then return true end
    end
    return false
end

----------------------------------------------------------------------
-- TargetScanner
----------------------------------------------------------------------
local TargetScanner = {}
TargetScanner.Candidates = {}   -- [Model] = Humanoid
TargetScanner.Cache = {}        -- sorted list of {Model, Humanoid, Root, Distance}
TargetScanner.Interval = 0.15

local scanAccumulator = 0
local SCAN_FEATURES = {
    "TeleDron", "TeleKill", "Aimbot", "AimMagic", "AutoFire", "HitboxAllMod", "AllModIm",
    "EspLine", "EspBox", "EspName", "EspDistance", "EspHologram",
}

local function RegisterHumanoid(hum)
    if not hum:IsA("Humanoid") then return end
    local model = hum.Parent
    if model and model:IsA("Model") then
        TargetScanner.Candidates[model] = hum
    end
end

function TargetScanner.Init()
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Humanoid") then
            RegisterHumanoid(d)
        end
    end
    Track(Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("Humanoid") then
            task.defer(RegisterHumanoid, d)
        end
    end))
    Track(Workspace.DescendantRemoving:Connect(function(d)
        if d:IsA("Humanoid") then
            local model = d.Parent
            if model then
                TargetScanner.Candidates[model] = nil
            end
        end
    end))
end

function TargetScanner.IsValidModel(model, hum, origin)
    if not model or not model.Parent or not model:IsDescendantOf(Workspace) then return false end
    if model == LocalPlayer.Character then return false end
    if Players:GetPlayerFromCharacter(model) ~= nil then return false end
    if not hum or hum.Parent ~= model or hum.Health <= 0 then return false end
    local root = GetModelRoot(model)
    if not root then return false end
    if origin and (root.Position - origin).Magnitude > StateManager.Config.ScanRange then return false end
    return true
end

function TargetScanner.Refresh()
    local _, _, hrp = GetCharacter()
    local list = {}
    if hrp then
        local origin = hrp.Position
        for model, hum in pairs(TargetScanner.Candidates) do
            if TargetScanner.IsValidModel(model, hum, origin) then
                local root = GetModelRoot(model)
                table.insert(list, {
                    Model = model,
                    Humanoid = hum,
                    Root = root,
                    Distance = (root.Position - origin).Magnitude,
                })
            elseif not model.Parent then
                TargetScanner.Candidates[model] = nil
            end
        end
        table.sort(list, function(a, b) return a.Distance < b.Distance end)
    end
    TargetScanner.Cache = list
end

function TargetScanner.GetList()
    return TargetScanner.Cache
end

function TargetScanner.GetNearest()
    return TargetScanner.Cache[1]
end

function TargetScanner.Step(dt)
    if not StateManager.AnyEnabled(SCAN_FEATURES) then
        if #TargetScanner.Cache > 0 then TargetScanner.Cache = {} end
        return
    end
    scanAccumulator += dt
    if scanAccumulator >= TargetScanner.Interval then
        scanAccumulator = 0
        TargetScanner.Refresh()
    end
end

----------------------------------------------------------------------
-- CombatEngine
----------------------------------------------------------------------
local CombatEngine = {}
CombatEngine.Locked = nil -- entry {Model, Humanoid, Root}
-- CÁCH CẮM CƠ CHẾ TẤN CÔNG CỦA GAME:
-- Gán CombatEngine.CustomHook = function(target, mode, aimWorldPos) ... end
--   target       = {Model, Humanoid, Root}
--   mode         = "TeleDron" | "TeleKill" | "AutoFire" | "AimMagic"
--   aimWorldPos  = tọa độ thế giới điểm ngắm (đầu/tâm mục tiêu)
-- Ví dụ: game:GetService("ReplicatedStorage").TestAttack:FireServer(target.Model, aimWorldPos)
-- Nếu hook không được gán (hoặc lỗi), AttackHook sẽ tự gọi Tool:Activate().
CombatEngine.CustomHook = nil
CombatEngine.LastFire = 0

local droneBP, droneBG

function CombatEngine.GetTarget()
    local _, _, hrp = GetCharacter()
    if not hrp then
        CombatEngine.Locked = nil
        return nil
    end
    local locked = CombatEngine.Locked
    if locked and TargetScanner.IsValidModel(locked.Model, locked.Humanoid, hrp.Position) then
        return locked
    end
    local nearest = TargetScanner.GetNearest()
    if nearest and TargetScanner.IsValidModel(nearest.Model, nearest.Humanoid, hrp.Position) then
        CombatEngine.Locked = nearest
        return nearest
    end
    CombatEngine.Locked = nil
    return nil
end

function CombatEngine.AttackHook(target, mode, aimWorldPos)
    if not target then return end
    if CombatEngine.CustomHook then
        local ok = pcall(CombatEngine.CustomHook, target, mode, aimWorldPos)
        if ok then return end
    end
    local char, hum = GetCharacter()
    if not char or not hum then return end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then
        local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
        local candidate = backpack and backpack:FindFirstChildOfClass("Tool")
        if candidate then
            pcall(function() hum:EquipTool(candidate) end)
            tool = candidate
        end
    end
    if tool then
        pcall(function() tool:Activate() end)
    end
end

function CombatEngine.Fire(target, mode, aimWorldPos)
    local now = os.clock()
    if now - CombatEngine.LastFire < StateManager.Config.FireInterval then return end
    CombatEngine.LastFire = now
    CombatEngine.AttackHook(target, mode, aimWorldPos)
end

local function DestroyDrone()
    if droneBP then droneBP:Destroy() droneBP = nil end
    if droneBG then droneBG:Destroy() droneBG = nil end
end

-- Hitbox All Mod / All Mod Im ----------------------------------------
-- Lưu ý: đây là thay đổi phía client (Snapshot + khôi phục sạch khi tắt).
-- Sát thương thật phụ thuộc cách game phát hiện va chạm (server/client).
local hitboxSnap = {} -- [BasePart] = {Size, CanCollide, Transparency, Massless}
local freezeSnap = {} -- [Humanoid] = {WalkSpeed, JumpPower, JumpHeight, AutoRotate, Root, Anchored}

local function ExpandPart(part, size)
    local snap = hitboxSnap[part]
    if not snap then
        snap = {
            Size = part.Size, CanCollide = part.CanCollide,
            Transparency = part.Transparency, Massless = part.Massless,
        }
        hitboxSnap[part] = snap
    end
    if part.Size ~= size then part.Size = size end -- hộp lập phương: phủ cả vùng dưới mặt đất
    if part.CanCollide then part.CanCollide = false end -- không bị tường/vật cản chặn
    if not part.Massless then part.Massless = true end
    local t = math.max(snap.Transparency, 0.7)
    if part.Transparency ~= t then part.Transparency = t end
end

local function RestoreHitboxPart(part)
    local snap = hitboxSnap[part]
    hitboxSnap[part] = nil
    if snap and part.Parent then
        pcall(function()
            part.Size = snap.Size
            part.CanCollide = snap.CanCollide
            part.Transparency = snap.Transparency
            part.Massless = snap.Massless
        end)
    end
end

local function RestoreAllHitboxes()
    for part in pairs(hitboxSnap) do
        RestoreHitboxPart(part)
    end
end

local function CollectToolHandles(out)
    local containers = {}
    if LocalPlayer.Character then table.insert(containers, LocalPlayer.Character) end
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then table.insert(containers, backpack) end
    for _, container in ipairs(containers) do
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") then
                local handle = tool:FindFirstChild("Handle")
                if handle and handle:IsA("BasePart") then
                    out[handle] = true
                end
            end
        end
    end
end

local function FreezeMob(hum, root)
    if not freezeSnap[hum] then
        freezeSnap[hum] = {
            WalkSpeed = hum.WalkSpeed, JumpPower = hum.JumpPower, JumpHeight = hum.JumpHeight,
            AutoRotate = hum.AutoRotate, Root = root, Anchored = root.Anchored,
        }
    end
    hum.WalkSpeed = 0
    hum.JumpPower = 0
    hum.JumpHeight = 0
    hum.AutoRotate = false
    root.AssemblyLinearVelocity = Vector3.zero
    if not root.Anchored then root.Anchored = true end
end

local function RestoreFreeze(hum)
    local snap = freezeSnap[hum]
    freezeSnap[hum] = nil
    if not snap then return end
    if hum.Parent then
        pcall(function()
            hum.WalkSpeed = snap.WalkSpeed
            hum.JumpPower = snap.JumpPower
            hum.JumpHeight = snap.JumpHeight
            hum.AutoRotate = snap.AutoRotate
        end)
    end
    if snap.Root and snap.Root.Parent then
        snap.Root.Anchored = snap.Anchored
    end
end

local function RestoreAllFreeze()
    for hum in pairs(freezeSnap) do
        RestoreFreeze(hum)
    end
end

function CombatEngine.StepModifiers()
    local flags = StateManager.Flags
    if not (flags.HitboxAllMod or flags.AllModIm) then return end
    local list = TargetScanner.GetList()

    if flags.HitboxAllMod then
        local s = StateManager.Config.HitboxSize
        local size = Vector3.new(s, s, s)
        local active = {}
        for _, t in ipairs(list) do
            active[t.Root] = true
            ExpandPart(t.Root, size)
        end
        local handles = {}
        CollectToolHandles(handles)
        for handle in pairs(handles) do
            active[handle] = true
            ExpandPart(handle, size)
        end
        -- Khôi phục phần tử đã rời phạm vi / chết / bị hủy
        for part in pairs(hitboxSnap) do
            if not active[part] then RestoreHitboxPart(part) end
        end
    end

    if flags.AllModIm then
        local active = {}
        for _, t in ipairs(list) do
            active[t.Humanoid] = true
            FreezeMob(t.Humanoid, t.Root)
        end
        for hum in pairs(freezeSnap) do
            if not active[hum] then RestoreFreeze(hum) end
        end
    end
end

function CombatEngine.Init()
    StateManager.OnChanged("TeleDron", function(on)
        if not on then DestroyDrone() end
    end)
    StateManager.OnChanged("HitboxAllMod", function(on)
        if not on then RestoreAllHitboxes() end
    end)
    StateManager.OnChanged("AllModIm", function(on)
        if not on then RestoreAllFreeze() end
    end)

    -- Aim Magic: không đụng Camera, chỉ tính aimWorldPos khi bấm/chạm
    Track(UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if not StateManager.Flags.AimMagic then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            local target = CombatEngine.GetTarget()
            if target then
                CombatEngine.AttackHook(target, "AimMagic", GetAimPosition(target.Model))
            end
        end
    end))

    Track(RunService.Heartbeat:Connect(function()
        local flags = StateManager.Flags
        local _, hum, hrp = GetCharacter()

        CombatEngine.StepModifiers()

        if not (flags.TeleDron or flags.TeleKill or flags.AutoFire) then
            return
        end
        if not hrp or not hum then return end

        local target = CombatEngine.GetTarget()

        if flags.TeleDron then
            if not droneBP or droneBP.Parent ~= hrp then
                DestroyDrone()
                droneBP = Instance.new("BodyPosition")
                droneBP.MaxForce = Vector3.new(1, 1, 1) * 1e9
                droneBP.P = 40000
                droneBP.D = 2500
                droneBP.Position = hrp.Position
                droneBP.Parent = hrp
                droneBG = Instance.new("BodyGyro")
                droneBG.MaxTorque = Vector3.new(1, 1, 1) * 1e9
                droneBG.P = 20000
                droneBG.CFrame = hrp.CFrame
                droneBG.Parent = hrp
            end
            hrp.AssemblyLinearVelocity = Vector3.zero
            if target then
                local tpos = target.Root.Position
                droneBP.Position = tpos + Vector3.new(0, StateManager.Config.DroneHeightOffset, 0)
                droneBG.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(tpos.X, hrp.Position.Y, tpos.Z))
                CombatEngine.Fire(target, "TeleDron", GetAimPosition(target.Model))
            else
                droneBP.Position = hrp.Position
            end
        end

        if flags.TeleKill and target then
            local tcf = target.Root.CFrame
            local pos = tcf:PointToWorldSpace(Vector3.new(0, 0, StateManager.Config.KillOffset))
            hrp.CFrame = CFrame.lookAt(pos, Vector3.new(tcf.Position.X, pos.Y, tcf.Position.Z))
            hrp.AssemblyLinearVelocity = Vector3.zero
            CombatEngine.Fire(target, "TeleKill", GetAimPosition(target.Model))
        end

        if flags.AutoFire and target then
            CombatEngine.Fire(target, "AutoFire", GetAimPosition(target.Model))
        end
    end))

    -- Aimbot: xoay mượt Camera
    local lastAimModel = nil
    Track(RunService.RenderStepped:Connect(function()
        if not StateManager.Flags.Aimbot then
            lastAimModel = nil
            return
        end
        local cam = Workspace.CurrentCamera
        if not cam then return end
        local target = CombatEngine.GetTarget()
        if not target then
            lastAimModel = nil
            return
        end
        local camPos = cam.CFrame.Position
        local desired = CFrame.lookAt(camPos, GetAimPosition(target.Model))
        local alpha = StateManager.Config.AimSmoothness
        if lastAimModel ~= target.Model then
            lastAimModel = target.Model
            alpha = math.min(alpha, 0.12) -- chuyển mục tiêu mượt hơn, chống giật
        end
        local dot = math.clamp(cam.CFrame.LookVector:Dot(desired.LookVector), -1, 1)
        if math.acos(dot) < math.rad(0.3) then return end -- vùng chết chống rung
        cam.CFrame = cam.CFrame:Lerp(desired, alpha)
    end))
end

function CombatEngine.Cleanup()
    DestroyDrone()
    RestoreAllHitboxes()
    RestoreAllFreeze()
    CombatEngine.Locked = nil
end

----------------------------------------------------------------------
-- Drawing layer (dùng Drawing nếu có, nếu không dùng shim bằng GUI)
----------------------------------------------------------------------
local DrawingLayer = {}
local shimGui

local function EnsureShimGui()
    if shimGui and shimGui.Parent then return shimGui end
    shimGui = Instance.new("ScreenGui")
    shimGui.Name = "MCM_EspLayer"
    shimGui.IgnoreGuiInset = true
    shimGui.ResetOnSpawn = false
    shimGui.DisplayOrder = 500
    shimGui.Parent = GetGuiParent()
    return shimGui
end

local function MakeShim(kind)
    local frame = Instance.new("Frame")
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.BackgroundTransparency = 1
    frame.Parent = EnsureShimGui()

    local label, stroke
    if kind == "Text" then
        label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.GothamBold
        label.TextStrokeTransparency = 0
        label.Parent = frame
    elseif kind == "Square" then
        stroke = Instance.new("UIStroke")
        stroke.Parent = frame
    elseif kind == "Line" then
        frame.BackgroundTransparency = 0
    end

    local data = {
        Visible = false, Color = Color3.new(1, 1, 1), Thickness = 1,
        From = Vector2.zero, To = Vector2.zero,
        Position = Vector2.zero, Size = Vector2.new(0, 0),
        Text = "", Center = false, Outline = true, Filled = false, Transparency = 1,
    }

    local function refresh()
        frame.Visible = data.Visible
        if not data.Visible then return end
        if kind == "Line" then
            local a, b = data.From, data.To
            local d = b - a
            frame.BackgroundColor3 = data.Color
            frame.AnchorPoint = Vector2.new(0.5, 0.5)
            frame.Size = UDim2.fromOffset(d.Magnitude, math.max(1, data.Thickness))
            frame.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
            frame.Rotation = math.deg(math.atan2(d.Y, d.X))
        elseif kind == "Square" then
            frame.AnchorPoint = Vector2.zero
            frame.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
            frame.Size = UDim2.fromOffset(data.Size.X, data.Size.Y)
            stroke.Color = data.Color
            stroke.Thickness = data.Thickness
        elseif kind == "Text" then
            local textSize = data.Size and data.Size.X == 0 and 14 or 14
            frame.AnchorPoint = data.Center and Vector2.new(0.5, 0) or Vector2.zero
            frame.Size = UDim2.fromOffset(220, 18)
            frame.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
            label.Text = data.Text
            label.TextColor3 = data.Color
            label.TextSize = textSize
        end
    end

    return setmetatable({}, {
        __index = function(_, k)
            if k == "Remove" or k == "Destroy" then
                return function() frame:Destroy() end
            end
            return data[k]
        end,
        __newindex = function(_, k, v)
            if k == "Size" and kind == "Text" then
                data.Size = type(v) == "number" and Vector2.new(v, v) or v
            else
                data[k] = v
            end
            refresh()
        end,
    })
end

function DrawingLayer.New(kind)
    if typeof(Drawing) == "table" and Drawing.new then
        local ok, obj = pcall(Drawing.new, kind)
        if ok and obj then return obj end
    end
    return MakeShim(kind)
end

function DrawingLayer.Kill(obj)
    if obj then
        pcall(function() obj:Remove() end)
    end
end

function DrawingLayer.Shutdown()
    if shimGui then shimGui:Destroy() shimGui = nil end
end

----------------------------------------------------------------------
-- EspEngine
----------------------------------------------------------------------
local EspEngine = {}
EspEngine.Entries = {}        -- [Model] = {Line, Box, Name, Dist, Highlight}
EspEngine.ItemHighlights = {} -- [Instance] = Highlight
EspEngine.Container = nil

local ESP_FEATURES = { "EspLine", "EspBox", "EspName", "EspDistance", "EspHologram", "EspWorkspace" }
local itemAccumulator = 0

local function GetContainer()
    if EspEngine.Container and EspEngine.Container.Parent then return EspEngine.Container end
    local folder = Instance.new("Folder")
    folder.Name = "MCM_Highlights"
    folder.Parent = Workspace.CurrentCamera or Workspace
    EspEngine.Container = folder
    return folder
end

local function MakeHighlight(adornee, color)
    local h = Instance.new("Highlight")
    h.Adornee = adornee
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.FillColor = color
    h.FillTransparency = 0.6
    h.OutlineColor = Color3.new(1, 1, 1)
    h.OutlineTransparency = 0
    h.Parent = GetContainer()
    return h
end

local function DestroyEntry(entry)
    DrawingLayer.Kill(entry.Line)
    DrawingLayer.Kill(entry.Box)
    DrawingLayer.Kill(entry.Name)
    DrawingLayer.Kill(entry.Dist)
    if entry.Highlight then entry.Highlight:Destroy() end
end

local function HideEntry(entry)
    if entry.Line then entry.Line.Visible = false end
    if entry.Box then entry.Box.Visible = false end
    if entry.Name then entry.Name.Visible = false end
    if entry.Dist then entry.Dist.Visible = false end
end

local function NewEntry()
    local line = DrawingLayer.New("Line")
    line.Color = Color3.fromRGB(255, 80, 80)
    line.Thickness = 1
    line.Visible = false

    local box = DrawingLayer.New("Square")
    box.Color = Color3.fromRGB(255, 255, 0)
    box.Thickness = 1
    box.Filled = false
    box.Visible = false

    local name = DrawingLayer.New("Text")
    name.Size = 14
    name.Center = true
    name.Outline = true
    name.Color = Color3.new(1, 1, 1)
    name.Visible = false

    local dist = DrawingLayer.New("Text")
    dist.Size = 13
    dist.Center = true
    dist.Outline = true
    dist.Color = Color3.fromRGB(150, 255, 150)
    dist.Visible = false

    return { Line = line, Box = box, Name = name, Dist = dist, Highlight = nil }
end

function EspEngine.Cleanup()
    for model, entry in pairs(EspEngine.Entries) do
        DestroyEntry(entry)
        EspEngine.Entries[model] = nil
    end
    for inst, h in pairs(EspEngine.ItemHighlights) do
        h:Destroy()
        EspEngine.ItemHighlights[inst] = nil
    end
    if EspEngine.Container then
        EspEngine.Container:Destroy()
        EspEngine.Container = nil
    end
end

local function ClearItemHighlights()
    for inst, h in pairs(EspEngine.ItemHighlights) do
        h:Destroy()
        EspEngine.ItemHighlights[inst] = nil
    end
end

local function UpdateWorkspaceItems(origin)
    local itemFolder = Workspace:FindFirstChild("Item")
    if not itemFolder then
        ClearItemHighlights()
        return
    end
    local range = StateManager.Config.ScanRange
    local seen = {}
    for _, child in ipairs(itemFolder:GetChildren()) do
        if child:IsA("Model") or child:IsA("BasePart") then
            local ok, pivot = pcall(function() return child:GetPivot().Position end)
            if ok and (pivot - origin).Magnitude <= range then
                seen[child] = true
                if not EspEngine.ItemHighlights[child] then
                    EspEngine.ItemHighlights[child] = MakeHighlight(child, Color3.fromRGB(80, 200, 255))
                end
            end
        end
    end
    for inst, h in pairs(EspEngine.ItemHighlights) do
        if not seen[inst] or not inst.Parent then
            h:Destroy()
            EspEngine.ItemHighlights[inst] = nil
        end
    end
end

function EspEngine.Init()
    StateManager.OnChanged("EspWorkspace", function(on)
        if not on then ClearItemHighlights() end
    end)
    StateManager.OnChanged("EspHologram", function(on)
        if not on then
            for _, entry in pairs(EspEngine.Entries) do
                if entry.Highlight then
                    entry.Highlight:Destroy()
                    entry.Highlight = nil
                end
            end
        end
    end)

    Track(RunService.RenderStepped:Connect(function(dt)
        if not StateManager.AnyEnabled(ESP_FEATURES) then
            if next(EspEngine.Entries) or next(EspEngine.ItemHighlights) or EspEngine.Container then
                EspEngine.Cleanup()
            end
            return
        end

        local cam = Workspace.CurrentCamera
        local _, _, hrp = GetCharacter()
        if not cam or not hrp then return end
        local flags = StateManager.Flags
        local viewport = cam.ViewportSize
        local anyDrawing = flags.EspLine or flags.EspBox or flags.EspName or flags.EspDistance

        -- Workspace.Item (throttle)
        if flags.EspWorkspace then
            itemAccumulator += dt
            if itemAccumulator >= 0.3 then
                itemAccumulator = 0
                UpdateWorkspaceItems(hrp.Position)
            end
        end

        local active = {}
        for _, t in ipairs(TargetScanner.GetList()) do
            local model = t.Model
            active[model] = true
            local entry = EspEngine.Entries[model]
            if not entry then
                entry = NewEntry()
                EspEngine.Entries[model] = entry
            end

            -- Hologram 3D
            if flags.EspHologram then
                if not entry.Highlight then
                    entry.Highlight = MakeHighlight(model, Color3.fromRGB(255, 60, 60))
                end
            elseif entry.Highlight then
                entry.Highlight:Destroy()
                entry.Highlight = nil
            end

            -- 2D
            if anyDrawing then
                local cf, size = model:GetBoundingBox()
                local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
                local visible = true
                for xi = -1, 1, 2 do
                    for yi = -1, 1, 2 do
                        for zi = -1, 1, 2 do
                            local corner = cf:PointToWorldSpace(Vector3.new(xi * size.X / 2, yi * size.Y / 2, zi * size.Z / 2))
                            local v = cam:WorldToViewportPoint(corner)
                            if v.Z <= 0 then
                                visible = false
                            else
                                minX = math.min(minX, v.X)
                                minY = math.min(minY, v.Y)
                                maxX = math.max(maxX, v.X)
                                maxY = math.max(maxY, v.Y)
                            end
                        end
                    end
                end

                if visible and maxX > minX and maxY > minY then
                    local cx = (minX + maxX) / 2
                    local cy = (minY + maxY) / 2

                    entry.Line.Visible = flags.EspLine == true
                    if flags.EspLine then
                        entry.Line.From = Vector2.new(viewport.X / 2, 0)
                        entry.Line.To = Vector2.new(cx, cy)
                    end

                    entry.Box.Visible = flags.EspBox == true
                    if flags.EspBox then
                        entry.Box.Position = Vector2.new(minX, minY)
                        entry.Box.Size = Vector2.new(maxX - minX, maxY - minY)
                    end

                    entry.Name.Visible = flags.EspName == true
                    if flags.EspName then
                        entry.Name.Text = model.Name
                        entry.Name.Position = Vector2.new(cx, minY - 18)
                    end

                    entry.Dist.Visible = flags.EspDistance == true
                    if flags.EspDistance then
                        entry.Dist.Text = string.format("%.0f studs", t.Distance)
                        entry.Dist.Position = Vector2.new(cx, maxY + 2)
                    end
                else
                    HideEntry(entry)
                end
            else
                HideEntry(entry)
            end
        end

        -- Dọn thực thể rời phạm vi
        for model, entry in pairs(EspEngine.Entries) do
            if not active[model] then
                DestroyEntry(entry)
                EspEngine.Entries[model] = nil
            end
        end
    end))
end

----------------------------------------------------------------------
-- MovementAndWorld
----------------------------------------------------------------------
local MovementAndWorld = {}
MovementAndWorld.VerticalHeld = { Up = false, Down = false }

local noclipOriginal = setmetatable({}, { __mode = "k" })
local flyBV, flyBG
local jumpConn
local lastAirJump = 0
local LastFlat = Vector3.new(0, 0, -1)
local lagOriginals = {}
local lagConn

local function DestroyFly()
    if flyBV then flyBV:Destroy() flyBV = nil end
    if flyBG then flyBG:Destroy() flyBG = nil end
end

local function RestoreNoClip()
    for part, original in pairs(noclipOriginal) do
        if part.Parent then
            part.CanCollide = original
        end
        noclipOriginal[part] = nil
    end
end

-- Lưu Snapshot CanCollide gốc rồi tắt va chạm các BasePart của nhân vật
local function ApplyNoClip()
    local char = LocalPlayer.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            if noclipOriginal[part] == nil then
                noclipOriginal[part] = part.CanCollide
            end
            part.CanCollide = false
        end
    end
end

-- Night Vision --------------------------------------------------------
local LIGHTING_PROPS = {
    "Brightness", "ClockTime", "FogEnd", "FogStart", "FogColor",
    "Ambient", "OutdoorAmbient", "ExposureCompensation", "GlobalShadows",
}

local function ApplyNightVision()
    local snap = {}
    snap.Lighting = {}
    for _, prop in ipairs(LIGHTING_PROPS) do
        snap.Lighting[prop] = Lighting[prop]
    end
    snap.Effects = {}
    for _, child in ipairs(Lighting:GetChildren()) do
        if child:IsA("Atmosphere") then
            snap.Effects[child] = { Density = child.Density, Haze = child.Haze }
            child.Density = 0
            child.Haze = 0
        elseif child:IsA("PostEffect") or child:IsA("SunRaysEffect") or child:IsA("BloomEffect")
            or child:IsA("BlurEffect") or child:IsA("DepthOfFieldEffect") or child:IsA("ColorCorrectionEffect") then
            snap.Effects[child] = { Enabled = child.Enabled }
            child.Enabled = false
        end
    end
    StateManager.Snapshot.NightVision = snap

    Lighting.Brightness = 3
    Lighting.ClockTime = 14
    Lighting.FogEnd = 1e6
    Lighting.FogStart = 1e6
    Lighting.Ambient = Color3.new(1, 1, 1)
    Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
    Lighting.ExposureCompensation = 0.5
    Lighting.GlobalShadows = false
end

local function RestoreNightVision()
    local snap = StateManager.Snapshot.NightVision
    if not snap then return end
    for prop, value in pairs(snap.Lighting) do
        pcall(function() Lighting[prop] = value end)
    end
    for inst, props in pairs(snap.Effects) do
        if inst.Parent then
            for prop, value in pairs(props) do
                pcall(function() inst[prop] = value end)
            end
        end
    end
    StateManager.Snapshot.NightVision = nil
end

-- Fix Lag -------------------------------------------------------------
local function LagOptimize(inst)
    if lagOriginals[inst] then return end
    if inst:IsA("BasePart") then
        lagOriginals[inst] = { CastShadow = inst.CastShadow }
        inst.CastShadow = false
    elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
        or inst:IsA("Fire") or inst:IsA("Smoke") then
        lagOriginals[inst] = { Enabled = inst.Enabled }
        inst.Enabled = false
    elseif inst:IsA("Decal") or inst:IsA("Texture") then
        lagOriginals[inst] = { Transparency = inst.Transparency }
        inst.Transparency = 0.9
    elseif inst:IsA("PostEffect") then
        -- Bỏ qua hiệu ứng đã do Night Vision quản lý để tránh xung đột Snapshot
        local nv = StateManager.Snapshot.NightVision
        if nv and nv.Effects[inst] then return end
        lagOriginals[inst] = { Enabled = inst.Enabled }
        inst.Enabled = false
    end
end

local function ApplyFixLag()
    StateManager.Snapshot.GlobalShadows = Lighting.GlobalShadows
    Lighting.GlobalShadows = false
    for _, inst in ipairs(Lighting:GetChildren()) do
        LagOptimize(inst) -- hậu kỳ (Bloom/Blur/SunRays/DoF/ColorCorrection)
    end
    task.spawn(function()
        local count = 0
        for _, inst in ipairs(Workspace:GetDescendants()) do
            if not StateManager.Flags.FixLag then return end
            LagOptimize(inst)
            count += 1
            if count % 400 == 0 then task.wait() end
        end
    end)
    lagConn = Workspace.DescendantAdded:Connect(function(inst)
        if StateManager.Flags.FixLag then
            LagOptimize(inst)
        end
    end)
end

local function RestoreFixLag()
    if lagConn then lagConn:Disconnect() lagConn = nil end
    if StateManager.Snapshot.GlobalShadows ~= nil then
        Lighting.GlobalShadows = StateManager.Snapshot.GlobalShadows
        StateManager.Snapshot.GlobalShadows = nil
    end
    task.spawn(function()
        local count = 0
        for inst, props in pairs(lagOriginals) do
            if inst.Parent then
                for prop, value in pairs(props) do
                    pcall(function() inst[prop] = value end)
                end
            end
            lagOriginals[inst] = nil
            count += 1
            if count % 400 == 0 then task.wait() end
        end
    end)
end

local function AnyFlight()
    local f = StateManager.Flags
    return f.FlyAir == true or f.FlyDown == true or f.FlyDron == true
end

local flightRayParams = RaycastParams.new()
flightRayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Tư thế nằm: đầu hướng về phía trước; faceUp=true: ngửa mặt lên, false: úp mặt xuống
local function PoseCFrame(forward, faceUp)
    local back = faceUp and Vector3.new(0, -1, 0) or Vector3.new(0, 1, 0)
    local right = forward:Cross(back)
    return CFrame.fromMatrix(Vector3.zero, right, forward, back)
end

-- Bước điều khiển bay chung cho FlyAir / FlyDown / FlyDron
function MovementAndWorld.StepFlight(dt, hum, hrp)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local flags = StateManager.Flags
    local cfg = StateManager.Config

    if not flyBV or flyBV.Parent ~= hrp then
        DestroyFly()
        flyBV = Instance.new("BodyVelocity")
        flyBV.MaxForce = Vector3.new(1, 1, 1) * 1e9
        flyBV.Velocity = Vector3.zero
        flyBV.Parent = hrp
        flyBG = Instance.new("BodyGyro")
        flyBG.MaxTorque = Vector3.new(1, 1, 1) * 1e9
        flyBG.P = 15000
        flyBG.CFrame = hrp.CFrame
        flyBG.Parent = hrp
    end

    if StateManager.Snapshot.PlatformStand == nil then
        StateManager.Snapshot.PlatformStand = hum.PlatformStand
    end
    hum.PlatformStand = true

    local speed = cfg.FlySpeed
    local moveDir = hum.MoveDirection
    local look = cam.CFrame.LookVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    if flatLook.Magnitude > 0.01 then LastFlat = flatLook.Unit end

    local held = MovementAndWorld.VerticalHeld
    local vInput = (held.Up and 1 or 0) - (held.Down and 1 or 0)
    local velocity = Vector3.zero
    local gyro

    if flags.FlyAir then
        -- Đứng yên = vận tốc 0 => không rơi, giữ nguyên độ cao
        if moveDir.Magnitude > 0.05 then
            velocity = moveDir * speed
            if flatLook.Magnitude > 0.01 then
                local dot = moveDir:Dot(flatLook.Unit)
                velocity += Vector3.new(0, look.Y * dot * speed, 0)
            end
        end
        velocity += Vector3.new(0, vInput * speed, 0)
        gyro = CFrame.lookAt(Vector3.zero, LastFlat)
    elseif flags.FlyDown then
        -- Nằm ngửa, không tự tăng/giảm khi không bấm; camera không bị can thiệp
        velocity = moveDir * speed + Vector3.new(0, vInput * speed, 0)
        gyro = PoseCFrame(LastFlat, true)
    else
        -- Fly Dron: giữ độ cao cố định so với mặt đất, úp mặt xuống
        cfg.FlyDronHeight = math.clamp(cfg.FlyDronHeight + vInput * cfg.FlyAdjustRate * dt, 1, 300)
        local char = LocalPlayer.Character
        flightRayParams.FilterDescendantsInstances = char and { char } or {}
        local hit = Workspace:Raycast(hrp.Position, Vector3.new(0, -1000, 0), flightRayParams)
        local vy = 0
        if hit then
            local targetY = hit.Position.Y + cfg.FlyDronHeight
            vy = math.clamp((targetY - hrp.Position.Y) * 6, -speed, speed) -- lên/xuống từ từ
        end
        velocity = moveDir * speed + Vector3.new(0, vy, 0)
        gyro = PoseCFrame(LastFlat, false)
    end

    flyBV.Velocity = velocity
    flyBG.CFrame = gyro
end

function MovementAndWorld.Init()
    StateManager.OnChanged("NoClip", function(on)
        if not on and not StateManager.Flags.FlyDown then RestoreNoClip() end
    end)

    local function OnFlightChanged(on)
        if on or AnyFlight() then return end
        DestroyFly()
        local _, hum = GetCharacter()
        if hum and StateManager.Snapshot.PlatformStand ~= nil then
            hum.PlatformStand = StateManager.Snapshot.PlatformStand
        end
        StateManager.Snapshot.PlatformStand = nil
        MovementAndWorld.VerticalHeld.Up = false
        MovementAndWorld.VerticalHeld.Down = false
        if not StateManager.Flags.NoClip then RestoreNoClip() end
    end

    StateManager.OnChanged("FlyAir", OnFlightChanged)
    StateManager.OnChanged("FlyDron", OnFlightChanged)
    StateManager.OnChanged("FlyDown", function(on)
        if on then
            -- Tắt va chạm rồi hạ nhân vật xuống dưới mặt đất một lần
            ApplyNoClip()
            local _, _, hrp = GetCharacter()
            if hrp then
                hrp.CFrame = hrp.CFrame + Vector3.new(0, -StateManager.Config.FlyDownDepth, 0)
            end
        end
        OnFlightChanged(on)
    end)

    StateManager.OnChanged("Speed", function(on)
        if on then
            local _, hum = GetCharacter()
            if hum and StateManager.Snapshot.WalkSpeed == nil then
                StateManager.Snapshot.WalkSpeed = hum.WalkSpeed
            end
        else
            local _, hum = GetCharacter()
            if hum and StateManager.Snapshot.WalkSpeed ~= nil then
                hum.WalkSpeed = StateManager.Snapshot.WalkSpeed
            end
            StateManager.Snapshot.WalkSpeed = nil
        end
    end)

    StateManager.OnChanged("NightVision", function(on)
        if on then ApplyNightVision() else RestoreNightVision() end
    end)

    StateManager.OnChanged("FixLag", function(on)
        if on then ApplyFixLag() else RestoreFixLag() end
    end)

    jumpConn = Track(UserInputService.JumpRequest:Connect(function()
        if not StateManager.Flags.JumpingAir or AnyFlight() then return end
        local now = os.clock()
        if now - lastAirJump < 0.15 then return end -- debounce chống kẹt trạng thái
        lastAirJump = now
        local _, hum = GetCharacter()
        if hum and hum.Health > 0 then
            hum.PlatformStand = false
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end))

    Track(RunService.Stepped:Connect(function()
        if StateManager.Flags.NoClip or StateManager.Flags.FlyDown then
            ApplyNoClip()
        end
    end))

    Track(RunService.Heartbeat:Connect(function(dt)
        local flags = StateManager.Flags
        local _, hum, hrp = GetCharacter()
        if not hum or not hrp then return end

        if flags.Speed then
            if StateManager.Snapshot.WalkSpeed == nil then
                StateManager.Snapshot.WalkSpeed = hum.WalkSpeed
            end
            hum.WalkSpeed = StateManager.Config.WalkSpeed
        end

        if flags.FlyAir or flags.FlyDown or flags.FlyDron then
            MovementAndWorld.StepFlight(dt, hum, hrp)
        end
    end))
end

function MovementAndWorld.Cleanup()
    DestroyFly()
    RestoreNoClip()
    RestoreNightVision()
    RestoreFixLag()
    local _, hum = GetCharacter()
    if hum then
        if StateManager.Snapshot.PlatformStand ~= nil then
            hum.PlatformStand = StateManager.Snapshot.PlatformStand
        end
        if StateManager.Snapshot.WalkSpeed ~= nil then
            hum.WalkSpeed = StateManager.Snapshot.WalkSpeed
        end
    end
    StateManager.Snapshot.PlatformStand = nil
    StateManager.Snapshot.WalkSpeed = nil
end

----------------------------------------------------------------------
-- UIController
----------------------------------------------------------------------
local UIController = {}
UIController.Gui = nil

local COLOR_BG = Color3.fromRGB(24, 26, 33)
local COLOR_PANEL = Color3.fromRGB(34, 37, 47)
local COLOR_ACCENT = Color3.fromRGB(70, 130, 255)
local COLOR_ON = Color3.fromRGB(60, 190, 100)
local COLOR_OFF = Color3.fromRGB(190, 70, 70)
local COLOR_TEXT = Color3.fromRGB(235, 235, 240)

local function Corner(inst, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 6)
    c.Parent = inst
    return c
end

local function MakeLabel(parent, text, size, position, alignment)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = size
    l.Position = position or UDim2.new()
    l.Font = Enum.Font.GothamMedium
    l.TextSize = 14
    l.TextColor3 = COLOR_TEXT
    l.TextXAlignment = alignment or Enum.TextXAlignment.Left
    l.Text = text
    l.Parent = parent
    return l
end

function UIController.Build()
    local gui = Instance.new("ScreenGui")
    gui.Name = "ModularControlMenu"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 1000
    gui.Parent = GetGuiParent()
    UIController.Gui = gui

    local FULL_SIZE = UDim2.fromOffset(310, 400)
    local COLLAPSED_SIZE = UDim2.fromOffset(310, 36)

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = FULL_SIZE
    main.Position = UDim2.new(0.5, -155, 0.2, 0)
    main.BackgroundColor3 = COLOR_BG
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    main.Parent = gui
    Corner(main, 10)

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = COLOR_ACCENT
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main

    MakeLabel(titleBar, "  QA Control Menu", UDim2.new(1, -80, 1, 0))

    local function TitleButton(text, xOffset)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(30, 26)
        b.Position = UDim2.new(1, xOffset, 0, 5)
        b.BackgroundColor3 = COLOR_BG
        b.TextColor3 = COLOR_TEXT
        b.Font = Enum.Font.GothamBold
        b.TextSize = 16
        b.Text = text
        b.AutoButtonColor = true
        b.Parent = titleBar
        Corner(b, 6)
        return b
    end

    local collapseBtn = TitleButton("–", -68)
    local closeBtn = TitleButton("✕", -34)

    -- Drag
    local dragging, dragStart, startPos = false, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    Track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))

    -- Body
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.BackgroundTransparency = 1
    body.Position = UDim2.new(0, 0, 0, 36)
    body.Size = UDim2.new(1, 0, 1, -36)
    body.Parent = main

    local tabBar = Instance.new("Frame")
    tabBar.BackgroundTransparency = 1
    tabBar.Size = UDim2.new(1, -12, 0, 32)
    tabBar.Position = UDim2.fromOffset(6, 6)
    tabBar.Parent = body
    local tabLayout = Instance.new("UIListLayout")
    tabLayout.FillDirection = Enum.FillDirection.Horizontal
    tabLayout.Padding = UDim.new(0, 6)
    tabLayout.Parent = tabBar

    local pagesHolder = Instance.new("Frame")
    pagesHolder.BackgroundTransparency = 1
    pagesHolder.Position = UDim2.fromOffset(6, 44)
    pagesHolder.Size = UDim2.new(1, -12, 1, -50)
    pagesHolder.Parent = body

    local pages, tabButtons = {}, {}
    local rowCounters = {}
    local rowDrag = nil

    local function NextOrder(page)
        rowCounters[page] = (rowCounters[page] or 0) + 1
        return rowCounters[page]
    end

    -- Tạo hàng chức năng có tay cầm ≡ để kéo lên/xuống sắp xếp lại
    local function NewRow(page)
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -8, 0, 34)
        row.BackgroundColor3 = COLOR_PANEL
        row.BorderSizePixel = 0
        row.LayoutOrder = NextOrder(page)
        row.Parent = page
        Corner(row, 6)

        local handle = Instance.new("TextButton")
        handle.Size = UDim2.fromOffset(26, 34)
        handle.BackgroundTransparency = 1
        handle.Text = "≡"
        handle.Font = Enum.Font.GothamBold
        handle.TextSize = 20
        handle.TextColor3 = Color3.fromRGB(150, 150, 160)
        handle.Parent = row

        handle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                rowDrag = { Row = row, Page = page }
                page.ScrollingEnabled = false
                row.BackgroundColor3 = COLOR_PANEL:Lerp(COLOR_ACCENT, 0.35)
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        rowDrag = nil
                        page.ScrollingEnabled = true
                        row.BackgroundColor3 = COLOR_PANEL
                    end
                end)
            end
        end)
        return row
    end

    Track(UserInputService.InputChanged:Connect(function(input)
        if not rowDrag then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        local row, page = rowDrag.Row, rowDrag.Page
        local y = UserInputService:GetMouseLocation().Y
        for _, other in ipairs(page:GetChildren()) do
            if other:IsA("Frame") and other ~= row then
                local top = other.AbsolutePosition.Y
                if y > top and y < top + other.AbsoluteSize.Y then
                    row.LayoutOrder, other.LayoutOrder = other.LayoutOrder, row.LayoutOrder
                    break
                end
            end
        end
    end))

    local function SelectTab(name)
        for n, page in pairs(pages) do
            page.Visible = (n == name)
            tabButtons[n].BackgroundColor3 = (n == name) and COLOR_ACCENT or COLOR_PANEL
        end
    end

    local function CreateTab(name)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1 / 3, -4, 1, 0)
        btn.BackgroundColor3 = COLOR_PANEL
        btn.TextColor3 = COLOR_TEXT
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 14
        btn.Text = name
        btn.Parent = tabBar
        Corner(btn, 6)
        tabButtons[name] = btn

        local page = Instance.new("ScrollingFrame")
        page.Size = UDim2.fromScale(1, 1)
        page.BackgroundTransparency = 1
        page.BorderSizePixel = 0
        page.ScrollBarThickness = 4
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.CanvasSize = UDim2.new()
        page.Visible = false
        page.Parent = pagesHolder
        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 6)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = page
        pages[name] = page

        btn.MouseButton1Click:Connect(function() SelectTab(name) end)
        return page
    end

    local function AddSection(page, text)
        local l = MakeLabel(page, text, UDim2.new(1, -8, 0, 20))
        l.Font = Enum.Font.GothamBold
        l.TextColor3 = COLOR_ACCENT
        l.TextSize = 13
        l.LayoutOrder = NextOrder(page)
    end

    local function AddToggle(page, text, flag)
        local row = NewRow(page)
        MakeLabel(row, text, UDim2.new(1, -100, 1, 0), UDim2.fromOffset(28, 0))

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(60, 24)
        btn.Position = UDim2.new(1, -66, 0.5, -12)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 13
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = row
        Corner(btn, 6)

        local function Refresh()
            local on = StateManager.Flags[flag] == true
            btn.Text = on and "ON" or "OFF"
            btn.BackgroundColor3 = on and COLOR_ON or COLOR_OFF
        end
        Refresh()

        btn.MouseButton1Click:Connect(function()
            StateManager.Toggle(flag)
        end)
        StateManager.OnAnyChanged(function(name)
            if name == flag then Refresh() end
        end)
    end

    local function AddInput(page, text, key, minV, maxV)
        local row = NewRow(page)
        MakeLabel(row, text, UDim2.new(1, -110, 1, 0), UDim2.fromOffset(28, 0))

        local box = Instance.new("TextBox")
        box.Size = UDim2.fromOffset(70, 24)
        box.Position = UDim2.new(1, -76, 0.5, -12)
        box.BackgroundColor3 = COLOR_BG
        box.TextColor3 = COLOR_TEXT
        box.Font = Enum.Font.GothamMedium
        box.TextSize = 13
        box.ClearTextOnFocus = false
        box.Text = tostring(StateManager.Config[key])
        box.Parent = row
        Corner(box, 6)

        box.FocusLost:Connect(function()
            local value = tonumber(box.Text)
            if value then
                value = StateManager.SetConfig(key, value, minV, maxV)
            else
                value = StateManager.Config[key]
            end
            box.Text = tostring(value)
        end)
    end

    -- TAB MAIN
    local mainPage = CreateTab("Main")
    AddSection(mainPage, "Phạm vi mặc định: 150 studs")
    AddToggle(mainPage, "Tele Dron", "TeleDron")
    AddToggle(mainPage, "Tele Kill", "TeleKill")
    AddToggle(mainPage, "Aimbot", "Aimbot")
    AddToggle(mainPage, "Aim Magic", "AimMagic")
    AddToggle(mainPage, "Auto Bắn", "AutoFire")
    AddInput(mainPage, "Scan Range", "ScanRange", 10, 2000)
    AddInput(mainPage, "Drone Height", "DroneHeightOffset", 0, 200)
    AddInput(mainPage, "Fire Interval", "FireInterval", 0.03, 5)

    -- TAB ESP
    local espPage = CreateTab("Esp")
    AddSection(espPage, "Phạm vi mặc định: 150 studs")
    AddToggle(espPage, "Esp Line", "EspLine")
    AddToggle(espPage, "Esp Box", "EspBox")
    AddToggle(espPage, "Esp Name", "EspName")
    AddToggle(espPage, "Esp Distance", "EspDistance")
    AddToggle(espPage, "Esp Hologram", "EspHologram")
    AddToggle(espPage, "Esp Workspace", "EspWorkspace")

    -- TAB KHÁC
    local otherPage = CreateTab("Khác")
    AddToggle(otherPage, "No Clip", "NoClip")
    AddToggle(otherPage, "Fly Air", "FlyAir")
    AddInput(otherPage, "Fly Speed", "FlySpeed", 1, 1000)
    AddToggle(otherPage, "Speed", "Speed")
    AddInput(otherPage, "Walk Speed", "WalkSpeed", 1, 1000)
    AddToggle(otherPage, "Jumping Air", "JumpingAir")
    AddToggle(otherPage, "Night Vision", "NightVision")
    AddToggle(otherPage, "Fix Lag", "FixLag")

    SelectTab("Main")

    -- Collapse / expand
    local collapsed = false
    collapseBtn.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        body.Visible = not collapsed
        main.Size = collapsed and COLLAPSED_SIZE or FULL_SIZE
        collapseBtn.Text = collapsed and "+" or "–"
    end)

    closeBtn.MouseButton1Click:Connect(function()
        if globalEnv.__ModularControlMenu then
            globalEnv.__ModularControlMenu.Shutdown()
        end
    end)

    -- Fly buttons
    local flyHolder = Instance.new("Frame")
    flyHolder.Name = "FlyButtons"
    flyHolder.BackgroundTransparency = 1
    flyHolder.Size = UDim2.fromOffset(80, 170)
    flyHolder.Position = UDim2.new(1, -100, 0.5, -85)
    flyHolder.Visible = false
    flyHolder.Parent = gui

    local function FlyButton(text, yOffset, key)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(80, 80)
        b.Position = UDim2.fromOffset(0, yOffset)
        b.BackgroundColor3 = COLOR_ACCENT
        b.BackgroundTransparency = 0.2
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 15
        b.TextWrapped = true
        b.Text = text
        b.AutoButtonColor = true
        b.Parent = flyHolder
        Corner(b, 12)

        b.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                MovementAndWorld.VerticalHeld[key] = true
            end
        end)
        b.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                MovementAndWorld.VerticalHeld[key] = false
            end
        end)
    end

    FlyButton("▲ Lên cao", 0, "Up")
    FlyButton("▼ Hạ thấp", 90, "Down")

    StateManager.OnChanged("FlyAir", function(on)
        flyHolder.Visible = on
    end)
end

function UIController.Destroy()
    if UIController.Gui then
        UIController.Gui:Destroy()
        UIController.Gui = nil
    end
end

----------------------------------------------------------------------
-- BOOTSTRAP
----------------------------------------------------------------------
local function Shutdown()
    for name in pairs(StateManager.Flags) do
        StateManager.Set(name, false)
    end
    CombatEngine.Cleanup()
    EspEngine.Cleanup()
    MovementAndWorld.Cleanup()
    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)
    DrawingLayer.Shutdown()
    UIController.Destroy()
    globalEnv.__ModularControlMenu = nil
end

TargetScanner.Init()
CombatEngine.Init()
EspEngine.Init()
MovementAndWorld.Init()
UIController.Build()

Track(RunService.Heartbeat:Connect(function(dt)
    TargetScanner.Step(dt)
end))

Track(LocalPlayer.CharacterAdded:Connect(function()
    CombatEngine.Locked = nil
    DestroyFly()
    DestroyDrone()
    table.clear(noclipOriginal)
end))

globalEnv.__ModularControlMenu = {
    Shutdown = Shutdown,
    StateManager = StateManager,
    TargetScanner = TargetScanner,
    CombatEngine = CombatEngine,
    EspEngine = EspEngine,
    MovementAndWorld = MovementAndWorld,
    UIController = UIController,
}
