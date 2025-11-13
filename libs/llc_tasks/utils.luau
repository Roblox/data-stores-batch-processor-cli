local m_utils = {}

function m_utils.notnil_or_default<T>(v: T?, d: T): T
    if v == nil then
        return d
    end
    return v
end

-- allows chaining member accesses forwarding nil if any intermediate step was nil
-- []/index to access members
-- () to get the value, optionally pass in a default
function m_utils.safe_access(t: { [any]: any }?)
    local v = {
        ___value = t,
    }

    setmetatable(v, {
        __index = function(_, k: any)
            if v.___value == nil then
                return v
            end
            v.___value = v.___value[k]
            return v
        end,

        __call = function(d: any?)
            if v.___value ~= nil then
                return v.___value :: any
            end
            return d
        end,
    })

    return v
end

return m_utils