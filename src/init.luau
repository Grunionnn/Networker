--[[
    Author: Grunion
    Referrals: @grunionnn (roblox), @_grunion_ (discord)
    Creation Date: 05/18/2026
    Script Description:
        Remote Event and Remote Function class wrapper for Roblox. Creates a Folder called Remotes on first server require
        and parents any future remotes to it. Remotes are made whenever they're needed. If you try to use a remote that
        doesn't exist yet, the server will create it and the client will wait for it. Returns connections from event
        listeners for cleanup.

    API:
        Networker.new(EventName: string, EventType: EventType?, Reliability: Reliability?): NetworkerEvent

        NetworkerEvent:FireServer(args: ...any)
        NetworkerEvent:FireClient(Target: Player, args: ...any)
        NetworkerEvent:FireAllClients(args: ...any)

        NetworkerEvent:OnServerEvent(function(Player: Player, args: ...any))
        NetworkerEvent:OnClientEvent(function(args: ...any))

        NetworkerEvent:InvokeServer(args: ...any)
        NetworkerEvent:InvokeClient(Target: Player, args: ...any)

        NetworkerEvent:OnServerInvoke(function(Player: Player, args: ...any))
        NetworkerEvent:OnClientInvoke(function(args: ...any))

    Usage:
        -- RemoteEvent
        -- Server Script
        local Networker = require(game:GetService("ReplicatedStorage").Modules.Networker)

        local purchaseEvent = Networker.new("PurchaseItem")

        purchaseEvent:OnServerEvent(function(Player: Player, ItemId: string)
            print(Player.Name, "wants to buy", ItemId)
        end)

        -- LocalScript
        local Networker = require(game:GetService("ReplicatedStorage").Modules.Networker)

        local purchaseEvent = Networker.new("PurchaseItem")

        purchaseEvent:FireServer("sword_001")

        -- RemoteFunction
        -- Server Script
        local Networker = require(game:GetService("ReplicatedStorage").Modules.Networker)

        local getCoinsEvent = Networker.new("GetCoins", "RemoteFunction")

        getCoinsEvent:OnServerInvoke(function(Player: Player)
            return 100
        end)

        -- LocalScript
        local Networker = require(game:GetService("ReplicatedStorage").Modules.Networker)

        local getCoinsEvent = Networker.new("GetCoins", "RemoteFunction")

        local Coins = getCoinsEvent:InvokeServer()
        print("Coins:", Coins)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Networker = {}
Networker.__index = Networker

-->> Types
type Reliability = "Reliable" | "Unreliable"
type EventType = "RemoteEvent" | "RemoteFunction"
type NetworkerData = {
	EventName: string,
	EventType: EventType?,
	Reliability: Reliability?,
	Event: RemoteEvent | RemoteFunction | UnreliableRemoteEvent,
}

export type NetworkerRemoteEvent = NetworkerData & {
	FireServer: (self: NetworkerRemoteEvent, ...any) -> (),
	FireClient: (self: NetworkerRemoteEvent, Target: Player, ...any) -> (),
	FireAllClients: (self: NetworkerRemoteEvent, ...any) -> (),
	OnClientEvent: (self: NetworkerRemoteEvent, fn: (...any) -> ()) -> RBXScriptConnection,
	OnServerEvent: (self: NetworkerRemoteEvent, fn: (plr: Player, ...any) -> ()) -> RBXScriptConnection,
}

export type NetworkerRemoteFunction = NetworkerData & {
	InvokeServer: (self: NetworkerRemoteFunction, ...any) -> ...any,
	InvokeClient: (self: NetworkerRemoteFunction, Target: Player, ...any) -> ...any,
	OnClientInvoke: (self: NetworkerRemoteFunction, fn: (...any) -> ()) -> (),
	OnServerInvoke: (self: NetworkerRemoteFunction, fn: (plr: Player, ...any) -> ()) -> (),
}

type NewSignature =
	((EventName: string, EventType: "RemoteFunction", Reliability: Reliability?) -> NetworkerRemoteFunction)
	& ((EventName: string, EventType: "RemoteEvent"?, Reliability: Reliability?) -> NetworkerRemoteEvent)

-->> Init
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	local folder = Instance.new("Folder")
	folder.Name = "Remotes"
	folder.Parent = ReplicatedStorage
	remotesFolder = folder
end

-->> Private Functions
local function GetRemote(
	EventName: string,
	EventType: EventType?,
	Reliability: Reliability?
): RemoteEvent | UnreliableRemoteEvent | RemoteFunction
	assert(remotesFolder, `[Networker]: Remotes Folder is nil`)

	local Remote = remotesFolder:FindFirstChild(EventName) :: RemoteEvent? | RemoteFunction? | UnreliableRemoteEvent?
	if Remote then
		return Remote
	end

	local isClient = RunService:IsClient()
	if isClient then
		return remotesFolder:WaitForChild(EventName) :: RemoteEvent | RemoteFunction | UnreliableRemoteEvent
	end

	if EventType == "RemoteFunction" then
		local event = Instance.new("RemoteFunction")
		event.Name = EventName
		event.Parent = remotesFolder
		return event
	end

	Reliability = Reliability or "Reliable"
	local event = Instance.new(Reliability == "Reliable" and "RemoteEvent" or "UnreliableRemoteEvent") :: RemoteEvent
	event.Name = EventName
	event.Parent = remotesFolder

	return event
end

-->> Constructor
Networker.new = (
	function(EventName: string, EventType: EventType?, Reliability: Reliability?)
		local self = setmetatable({} :: NetworkerData, Networker)

		self.EventName = EventName
		self.EventType = EventType or "RemoteEvent"
		self.Reliability = Reliability or "Reliable"
		self.Event = GetRemote(self.EventName, self.EventType, self.Reliability)

		return self
	end
) :: NewSignature

-->> Public Functions

-->> RemoteEvents
--* Sending events

function Networker.FireServer(self: NetworkerRemoteEvent, ...: any)
	assert(RunService:IsClient(), `[Networker]: Method "FireServer" can only be called from the client.`)

	local event = self.Event
	if event:IsA("RemoteEvent") or event:IsA("UnreliableRemoteEvent") then
		event:FireServer(...)
	else
		error(`[Networker]: Method "FireServer" can only be called if the event is a remote event.`)
	end
end

function Networker.FireClient(self: NetworkerRemoteEvent, Target: Player, ...: any)
	assert(RunService:IsServer(), `[Networker]: Method "FireClient" can only be called from the server.`)

	local event = self.Event
	if event:IsA("RemoteEvent") or event:IsA("UnreliableRemoteEvent") then
		event:FireClient(Target, ...)
	else
		error(`[Networker]: Method "FireClient" can only be called if the event is a remote event.`)
	end
end

function Networker.FireAllClients(self: NetworkerRemoteEvent, ...: any)
	assert(RunService:IsServer(), `[Networker]: Method "FireAllClients" can only be called from the server.`)

	local event = self.Event
	if event:IsA("RemoteEvent") or event:IsA("UnreliableRemoteEvent") then
		event:FireAllClients(...)
	else
		error(`[Networker]: Method "FireAllClients" can only be called if the event is a remote event.`)
	end
end

--* Receiving events

function Networker.OnServerEvent(self: NetworkerRemoteEvent, fn: (plr: Player, ...any) -> ()): RBXScriptConnection
	assert(RunService:IsServer(), `[Networker]: Method "OnServerEvent" can only be called from the server.`)

	local event = self.Event
	if event:IsA("RemoteEvent") or event:IsA("UnreliableRemoteEvent") then
		return event.OnServerEvent:Connect(fn)
	else
		error(`[Networker]: Method "OnServerEvent" can only be called if the event is a remote event.`)
	end
end

function Networker.OnClientEvent(self: NetworkerRemoteEvent, fn: (...any) -> ()): RBXScriptConnection
	assert(RunService:IsClient(), `[Networker]: Method "OnClientEvent" can only be called from the client.`)

	local event = self.Event
	if event:IsA("RemoteEvent") or event:IsA("UnreliableRemoteEvent") then
		return event.OnClientEvent:Connect(fn)
	else
		error(`[Networker]: Method "OnClientEvent" can only be called if the event is a remote event.`)
	end
end

-->> Remote Functions
--* Sending events

function Networker.InvokeServer(self: NetworkerRemoteFunction, ...: any): ...any
	assert(RunService:IsClient(), `[Networker]: Method "InvokeServer" can only be called from the client.`)

	local event = self.Event
	if event:IsA("RemoteFunction") then
		return event:InvokeServer(...)
	else
		error(`[Networker]: Method "InvokeServer" can only be called if the event is a remote function.`)
	end
end

function Networker.InvokeClient(self: NetworkerRemoteFunction, Target: Player, ...: any): ...any
	assert(RunService:IsServer(), `[Networker]: Method "InvokeClient" can only be called from the server.`)

	local event = self.Event
	if event:IsA("RemoteFunction") then
		return event:InvokeClient(Target, ...)
	else
		error(`[Networker]: Method "InvokeClient" can only be called if the event is a remote function.`)
	end
end

--* Receiving events

function Networker.OnServerInvoke(self: NetworkerRemoteFunction, fn: (plr: Player, ...any) -> ())
	assert(RunService:IsServer(), `[Networker]: Method "OnServerInvoke" can only be called from the server.`)

	local event = self.Event
	if event:IsA("RemoteFunction") then
		event.OnServerInvoke = fn
	else
		error(`[Networker]: Method "OnServerInvoke" can only be called if the event is a remote function.`)
	end
end

function Networker.OnClientInvoke(self: NetworkerRemoteFunction, fn: (...any) -> ())
	assert(RunService:IsClient(), `[Networker]: Method "OnClientInvoke" can only be called from the client.`)

	local event = self.Event
	if event:IsA("RemoteFunction") then
		event.OnClientInvoke = fn
	else
		error(`[Networker]: Method "OnClientInvoke" can only be called if the event is a remote function.`)
	end
end

return Networker
