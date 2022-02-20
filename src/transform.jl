abstract type AbstractHypercubeTransform end


"""
    `$(FUNCTIONNAME)(c::AbstractHypercubeTransform)`
Returns the dimension of the hypercube transform.
"""
function dimension end

"""
    `$(FUNCTIONNAME)(c)`
Constructs the object that contains the necessary information to move from
the unit hypercube to the distribution space. This is the usual function to use
when construct the transformation.

There are a few different behaviors depending on the type of the object.

 - If `c::Distribution` then this will store the distributions.
 - If `c::Tuple{AbstractHypercubeTransform}` then this will store the tuple

# Examples
```julia
ascube(Normal())
ascube(MultivariateNormal())
ascube((Normal(), Normal(2.0)))
ascube( (α = Uniform(), β = Normal()) )
```
"""
function ascube end

"""
    `$(FUNCTIONNAME)(c::AbstractHypercubeTransform, p)`
Transforms from the hypercube with coordinates `p`, to the parameter space
defined by the transformation `c`.

The behavior of this function depends on the nature of `c`.
 - If `c` is a <: Distributions.Distributions and has a quantile method
this will just call the quantile function. If no quantile function is defined
then a custom transformation depending on the type of `c` will be called. If
no custom transformation exists then an error will be raised.
 - If `c` is a Tuple of transformations then transform will iterate through the
 tuple using a similar method to the
 [TransformVariables.jl](https://github.com/tpapp/TransformVariables.jl) method.
"""
function transform end


struct ScalarHC{D} <: AbstractHypercubeTransform
    dist::D
    ScalarHC(d) = new{typeof(d)}(d)
end


# Trait to decide whether a quantile function is defined. This should be compile time right?
struct HasQuant end
struct NoQuant end
has_quantile(::ScalarHC{D}) where {D} = static_hasmethod(quantile, Tuple{D,Float64}) ? HasQuant() : NoQuant()


dimension(::ScalarHC) = 1
dist(d::ScalarHC) = d.dist
ascube(d::Dists.UnivariateDistribution) = ScalarHC(d)

"""
    $(SIGNATURES)
Computes the transformation from the unit hypercube to the distribution space.
"""
function transform(c::AbstractHypercubeTransform, x)
    @argcheck dimension(c) == length(x)
    return _transform(has_quantile(c), c, x)
end

function _transform(::HasQuant, c::AbstractHypercubeTransform, x)
    return quantile(dist(c), x)
end

function _transform(::NoQuant, c::AbstractHypercubeTransform, x)
    throw("No quantile for distribution $(c.dist), implement transform manually")
end

function _step_transform(c::ScalarHC, x::AbstractVector, index)
    transform(c, x[index]), index+1
end

inverse_eltype(::ScalarHC, x::Real) = float(typeof(x))


function _step_inverse!(y::AbstractVector, index, c::ScalarHC, x::Real)
    y[index] = _inverse(c, x)
    return index+1
end


abstract type VectorHC <: AbstractHypercubeTransform end

function transform(c::VectorHC, x::AbstractVector)
    @argcheck dimension(c) == length(x)
    return first(_step_transform(c, x, firstindex(x)))
end


struct ArrayHC{T,M} <: VectorHC
    dist::T
    dims::NTuple{M,Int}
end

dimension(c::ArrayHC) = prod(c.dims)

function ArrayHC(d)
    return ArrayHC{typeof(d),length(size(d))}(d, size(d))
end

ascube(d::Union{Dists.MultivariateDistribution,Dists.Matrixvariate}) = ArrayHC(d)
dist(d::ArrayHC) = d.dist

function inverse_eltype(::ArrayHC, x::AbstractArray{T}) where {T}
    float(T)
end


function _step_transform(h::ArrayHC{<:Dists.Product, M}, p::AbstractVector, index) where {M}
    out = Vector{eltype(p)}(undef, dimension(h))
    for i in 1:dimension(h)
        out[i] = first(_step_transform(ascube(dist(h).v[i]), p, index-1+i))
    end
    return out, index+dimension(h)
end

function _step_inverse!(x::AbstractVector, index, c::ArrayHC{<:Dists.Product, M}, y::AbstractVector) where {M}
    d = dist(c)
    for (i,yy) in enumerate(vec(y))
        index = _step_inverse!(x, index, ascube(d.v[i]), yy)
    end
    return index
end

dimension(c::ArrayHC{<:Dists.Dirichlet,M}) where {M} = prod(c.dims)-1
function _step_transform(h::ArrayHC{<:Dists.Dirichlet, M}, p::AbstractVector, index) where {M}
    d = dist(h)
    α = d.alpha
    T = promote_type(eltype(p), eltype(α))
    #println(T)
    out  = zeros(T, dimension(h)+1)
    #println(eltype(out))
    #dstart = Dists.Beta(T(α[1]), sum(@view(α[2:end])))
    #println(typeof(dstart))
    out[1] = quantile(Dists.Beta(T(α[1]), T(sum(@view(α[2:end])))), p[index])
    for i in 2:dimension(h)
        ϕ = quantile(Dists.Beta(T(α[i]),T(sum(@view(α[i+1:end])))), p[index-1+i])
        out[i] = T((1-sum(out))*ϕ)
    end
    out[end] = 1-sum(out)
    return out, index+dimension(h)
end

function _step_inverse!(x::AbstractVector, index, c::ArrayHC{<:Dists.Dirichlet, M}, y) where {M}
    d = dist(c)
    α = d.alpha
    #T = promote_type(eltype(p), eltype(α))
    x[index] = cdf(Dists.Beta(α[1], sum(@view(α[2:end]))), y[index])
    ysum = y[index]
    index += 1
    for _ in 2:dimension(c)
        x[index] = cdf(Dists.Beta(α[1], sum(@view(α[index+1:end]))), y[index]/(1-ysum))
        ysum += y[index]
        index+=1
    end
    return index
end

ascube(d::MT.ProductMeasure) = ArrayHC(d)


function _step_transform(h::ArrayHC{<:MT.ProductMeasure,M}, p::AbstractVector, index) where {M}
    out = Vector{eltype(p)}(undef, dimension(h))
    m = MT.marginals(dist(h))
    for (i,mi) in enumerate(m)
        out[i] = first(_step_transform(ascube(mi), p, index-1+i))
    end
    return out, index+dimension(h)
end

function _step_inverse!(x::AbstractVector, index, c::ArrayHC{<:MT.ProductMeasure, M}, y) where {M}
    m = MT.marginals(dist(c))
    for (mi, yy) in zip(m,vec(y))
        index = _step_inverse!(x, index, mi, yy)
    end
    return index
end
