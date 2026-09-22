--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = script.Parent
local RateLimiter = require(Packages.ratelimiter)
type RateLimiterInstance = typeof(RateLimiter.new(1, "HardCap"))

local isServer = RunService:IsServer()

local Networker = {}
Networker.__index = Networker

local function getFolder(parent: Instance, name: string): Folder
	local folder = parent:FindFirstChild(name)
	if not folder then
		if isServer then
			local created = Instance.new("Folder")
			created.Name = name
			created.Parent = parent
			folder = created
		else
			folder = parent:WaitForChild(name)
		end
	end
	assert(folder and folder:IsA("Folder"), name .. " must be a Folder")
	return folder
end

local remotesFolder = getFolder(ReplicatedStorage, "Remotes")
local remoteEventsFolder = getFolder(remotesFolder, "Events")
local remoteFunctionsFolder = getFolder(remotesFolder, "Functions")

export type EventRemote = {
	FireServer: (self: Networker, ...any) -> (),
	FireClient: (self: Networker, player: Player, ...any) -> (),
	FireAllClients: (self: Networker, ...any) -> (),
	OnServerEvent: (self: Networker, callback: (player: Player, ...any) -> ()) -> RBXScriptConnection,
	OnClientEvent: (self: Networker, callback: (...any) -> ()) -> RBXScriptConnection,
}

export type FunctionRemote = {
	InvokeServer: (self: Networker, ...any) -> any,
	InvokeClient: (self: Networker, player: Player, ...any) -> any,
	OnServerInvoke: (self: Networker, callback: (player: Player, ...any) -> any) -> (),
	OnClientInvoke: (self: Networker, callback: (...any) -> any) -> (),
}

type Networker = {
	remoteName: string,
	remoteType: "RemoteFunction" | "RemoteEvent",
	reliability: "Reliable" | "Unreliable" | nil,
	RateLimiter: RateLimiterInstance?,
	Remote: RemoteEvent | RemoteFunction | UnreliableRemoteEvent | nil,
	SetRateLimit: (
		self: Networker,
		maxRequests: number,
		limiterType: "Token" | "HardCap",
		tokenRefillRate: number?
	) -> (),
	Destroy: (self: Networker) -> (),
	_serverConnection: RBXScriptConnection | nil,
	_clientConnections: { RBXScriptConnection },
	_destroyed: boolean,
}

export type EventInstance = EventRemote & Networker
export type FunctionInstance = FunctionRemote & Networker

type Constructor =
	((name: string, kind: "RemoteEvent"?, reliability: ("Reliable" | "Unreliable")?) -> EventInstance)
	& ((name: string, kind: "RemoteFunction") -> FunctionInstance)

local serverInvokeOwners: { [RemoteFunction]: Networker } = {}
local clientInvokeOwners: { [RemoteFunction]: Networker } = {}

function Networker.new(
	remoteName: string,
	remoteType: ("RemoteFunction" | "RemoteEvent")?,
	reliability: ("Reliable" | "Unreliable")?
): EventInstance & FunctionInstance
	if remoteType == nil then
		remoteType = "RemoteEvent"
	end
	if reliability == nil then
		reliability = "Reliable"
	end
	assert(remoteType == "RemoteEvent" or remoteType == "RemoteFunction", "Invalid remote type")
	assert(reliability == "Reliable" or reliability == "Unreliable", "Invalid reliability")
	local folder = if remoteType == "RemoteEvent" then remoteEventsFolder else remoteFunctionsFolder
	local expectedClass = if remoteType == "RemoteFunction"
		then "RemoteFunction"
		elseif reliability == "Unreliable" then "UnreliableRemoteEvent"
		else "RemoteEvent"
	local remote = folder:FindFirstChild(remoteName)
	if not remote then
		if isServer then
			local created: Instance
			if expectedClass == "RemoteFunction" then
				created = Instance.new("RemoteFunction")
			elseif expectedClass == "UnreliableRemoteEvent" then
				created = Instance.new("UnreliableRemoteEvent")
			else
				created = Instance.new("RemoteEvent")
			end
			created.Name = remoteName
			created.Parent = folder
			remote = created
		else
			remote = folder:WaitForChild(remoteName)
		end
	end
	assert(remote, "Remote not found: " .. remoteName)
	assert(
		remote.ClassName == expectedClass,
		remoteName .. ": expected " .. expectedClass .. ", got " .. remote.ClassName
	)
	assert(
		remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") or remote:IsA("RemoteFunction"),
		"Expected a networking remote"
	)

	local self = setmetatable({} :: EventInstance & FunctionInstance, Networker)
	self.remoteName = remoteName
	self.remoteType = remoteType
	self.reliability = if remoteType == "RemoteEvent" then reliability else nil
	self.RateLimiter = nil
	self.Remote = remote :: RemoteEvent | UnreliableRemoteEvent | RemoteFunction
	self._serverConnection = nil
	self._clientConnections = {}
	self._destroyed = false
	return self
end

function Networker.Destroy(self: Networker): ()
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._serverConnection then
		self._serverConnection:Disconnect()
		self._serverConnection = nil
	end
	for _, connection in self._clientConnections do
		connection:Disconnect()
	end
	table.clear(self._clientConnections)
	if self.RateLimiter then
		self.RateLimiter:Destroy()
		self.RateLimiter = nil
	end
	local remote = self.Remote
	if remote and remote:IsA("RemoteFunction") then
		if serverInvokeOwners[remote] == self then
			(remote :: any).OnServerInvoke = nil
			serverInvokeOwners[remote] = nil
		end
		if clientInvokeOwners[remote] == self then
			(remote :: any).OnClientInvoke = nil
			clientInvokeOwners[remote] = nil
		end
	end
	self.Remote = nil
end

-->> Rate Limiter
function Networker.SetRateLimit(
	self: Networker,
	maxRequests: number,
	limiterType: "Token" | "HardCap",
	tokenRefillRate: number?
): ()
	assert(not self._destroyed, "Networker instance has been destroyed")
	assert(maxRequests > 0, "maxRequests must be greater than 0")
	assert(limiterType == "Token" or limiterType == "HardCap", "limiterType must be either 'Token' or 'HardCap'")
	assert(tokenRefillRate == nil or tokenRefillRate > 0, "tokenRefillRate must be greater than 0 if provided")
	assert(RunService:IsServer() == true, "SetRateLimit can only be called on the server")
	local replacement = RateLimiter.new(maxRequests, limiterType, tokenRefillRate)
	if self.RateLimiter then
		self.RateLimiter:Destroy()
	end
	self.RateLimiter = replacement
end

-->> Remote Events
--* Firing Events
function Networker.FireServer(self: Networker, ...: any): ()
	assert(self.remoteType == "RemoteEvent", "FireServer can only be called on RemoteEvents")
	assert(
		(self.Remote and self.Remote:IsA("RemoteEvent")) or (self.Remote and self.Remote:IsA("UnreliableRemoteEvent")),
		"Expected a RemoteEvent"
	)
	assert(RunService:IsServer() == false, "FireServer can only be called on the client")

	local remote = self.Remote
	remote:FireServer(...)
end

function Networker.FireClient(self: Networker, player: Player, ...: any): ()
	assert(self.remoteType == "RemoteEvent", "FireClient can only be called on RemoteEvents")
	assert(
		(self.Remote and self.Remote:IsA("RemoteEvent")) or (self.Remote and self.Remote:IsA("UnreliableRemoteEvent")),
		"Expected a RemoteEvent"
	)
	assert(RunService:IsServer() == true, "FireClient can only be called on the server")

	local remote = self.Remote
	remote:FireClient(player, ...)
end

function Networker.FireAllClients(self: Networker, ...: any): ()
	assert(self.remoteType == "RemoteEvent", "FireAllClients can only be called on RemoteEvents")
	assert(
		(self.Remote and self.Remote:IsA("RemoteEvent")) or (self.Remote and self.Remote:IsA("UnreliableRemoteEvent")),
		"Expected a RemoteEvent"
	)
	assert(RunService:IsServer() == true, "FireAllClients can only be called on the server")

	local remote = self.Remote
	remote:FireAllClients(...)
end

--* Connecting Events
function Networker.OnServerEvent(self: Networker, callback: (player: Player, ...any) -> ()): RBXScriptConnection
	assert(self.remoteType == "RemoteEvent", "OnServerEvent can only be called on RemoteEvents")
	assert(
		(self.Remote and self.Remote:IsA("RemoteEvent")) or (self.Remote and self.Remote:IsA("UnreliableRemoteEvent")),
		"Expected a RemoteEvent"
	)
	assert(RunService:IsServer() == true, "OnServerEvent can only be called on the server")
	assert(
		not self._serverConnection or not self._serverConnection.Connected,
		"OnServerEvent already has an active subscription"
	)

	local remote = self.Remote
	local function handler(player: Player, ...: any)
		if self._destroyed then
			return
		end
		local limiter = self.RateLimiter
		if limiter and not limiter:CanRequest(player) then
			return
		end

		callback(player, ...)
	end
	local conn = if remote:IsA("RemoteEvent")
		then remote.OnServerEvent:Connect(handler)
		else remote.OnServerEvent:Connect(handler)
	self._serverConnection = conn
	return conn
end

function Networker.OnClientEvent(self: Networker, callback: (...any) -> ()): RBXScriptConnection
	assert(self.remoteType == "RemoteEvent", "OnClientEvent can only be called on RemoteEvents")
	assert(
		(self.Remote and self.Remote:IsA("RemoteEvent")) or (self.Remote and self.Remote:IsA("UnreliableRemoteEvent")),
		"Expected a RemoteEvent"
	)
	assert(RunService:IsServer() == false, "OnClientEvent can only be called on the client")

	local remote = self.Remote
	local function handler(...: any)
		if not self._destroyed then
			callback(...)
		end
	end
	local connection = if remote:IsA("RemoteEvent")
		then remote.OnClientEvent:Connect(handler)
		else remote.OnClientEvent:Connect(handler)
	table.insert(self._clientConnections, connection)
	return connection
end

-->> Remote Functions
--* Invoking Functions
function Networker.InvokeServer(self: Networker, ...: any): any
	assert(self.remoteType == "RemoteFunction", "InvokeServer can only be called on RemoteFunctions")
	assert(self.Remote and self.Remote:IsA("RemoteFunction"), "Expected a RemoteFunction")
	assert(RunService:IsServer() == false, "InvokeServer can only be called on the client")

	local remote = self.Remote
	return remote:InvokeServer(...)
end

function Networker.InvokeClient(self: Networker, player: Player, ...: any): any
	assert(self.remoteType == "RemoteFunction", "InvokeClient can only be called on RemoteFunctions")
	assert(self.Remote and self.Remote:IsA("RemoteFunction"), "Expected a RemoteFunction")
	assert(RunService:IsServer() == true, "InvokeClient can only be called on the server")

	local remote = self.Remote
	return remote:InvokeClient(player, ...)
end

--* Connecting Functions
function Networker.OnServerInvoke(self: Networker, callback: (player: Player, ...any) -> any): ()
	assert(self.remoteType == "RemoteFunction", "OnServerInvoke can only be called on RemoteFunctions")
	assert(self.Remote and self.Remote:IsA("RemoteFunction"), "Expected a RemoteFunction")
	assert(RunService:IsServer() == true, "OnServerInvoke can only be called on the server")

	local remote = self.Remote
	remote.OnServerInvoke = function(player: Player, ...: any)
		assert(not self._destroyed, "Networker instance has been destroyed")
		local limiter = self.RateLimiter
		if limiter and not limiter:CanRequest(player) then
			return nil
		end

		return callback(player, ...)
	end
	serverInvokeOwners[remote] = self
end

function Networker.OnClientInvoke(self: Networker, callback: (...any) -> any): ()
	assert(self.remoteType == "RemoteFunction", "OnClientInvoke can only be called on RemoteFunctions")
	assert(self.Remote and self.Remote:IsA("RemoteFunction"), "Expected a RemoteFunction")
	assert(RunService:IsServer() == false, "OnClientInvoke can only be called on the client")

	local remote = self.Remote
	remote.OnClientInvoke = function(...: any)
		assert(not self._destroyed, "Networker instance has been destroyed")
		return callback(...)
	end
	clientInvokeOwners[remote] = self
end

return {
	new = Networker.new :: Constructor,
}
