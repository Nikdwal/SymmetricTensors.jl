module SymmetricMatrix
using NullableArrays
using Iterators
using Tensors
import Base: trace, vec, vecnorm, +, -, *, .*, /, \, ./, size, transpose, convert

seg(i::Int, of::Int, limit::Int) =  (i-1)*of+1 : ((i*of <= limit) ? i*of : limit)

function issymetric{T <: AbstractFloat}(data::Array{T}, atol::Float64 = 1e-7)
  for i=2:ndims(data)
    (maximum(abs(unfold(data, 1)-unfold(data, i))) < atol) || throw(DimensionMismatch("array is not symmetric"))
  end
end
segsizetest(len::Int, segments::Int) = ((len%segments) <= (len÷segments)) || throw(DimensionMismatch("last segment len $len-segments*(len÷segments)) > segment len $(len÷segments)"))

function structfeatures{T <: AbstractFloat, S}(frame::NullableArrays.NullableArray{Array{T,S},S})
  fsize = size(frame, 1)
  all(collect(size(frame)) .== fsize) || throw(DimensionMismatch("frame not square"))
  not_nulls = !frame.isnull
  !any(map(x->!issorted(ind2sub(not_nulls, x)), find(not_nulls))) || throw(ArgumentError("underdiagonal block not null"))
  quote
    @nloops $S i x->x==$S ? 1:fsize : i_{x+1}:fsize begin
      minimum(size($frame[i].value)) .== size($frame[i].value, 1) || throw(DimensionMismatch("[$i ] block not square"))
    end
  end
  for i=1:fsize
    issymetric(frame[fill(i, S)...].value)
  end
end

immutable BoxStructure{T <: AbstractFloat, S}
    frame::NullableArrays.NullableArray{Array{T,S},S}
    sizesegment::Int
    function call{T, S}(::Type{BoxStructure}, frame::NullableArrays.NullableArray{Array{T,S},S})
        structfeatures(frame)
        new{T, S}(frame, size(frame[fill(1,S)...].value,1))
    end
end

function convert{T <: AbstractFloat, N}(::Type{BoxStructure{T}}, data::Array{T, N}, segments::Int = 2)
  issymetric(data)
  len = size(data,1)
  segsizetest(len, segments)
  (len%segments == 0)? () : segments += 1
  ret = NullableArray(Array{T, N}, fill(segments, N)...)
  @eval begin
    @nloops $N i x -> (x==$N)? (1:$segments): (i_{x+1}:$segments) begin
      ind = @ntuple $N x -> i_{$N-x+1}
      @inbounds $ret[ind...] = $data[map(k::Int -> seg(k, ceil(Int, $len/$segments), $len), ind)...]
    end
  end
  BoxStructure(ret)
end

function readsegments{T <: AbstractFloat}(i::Array{Int}, bs::BoxStructure{T})
  sortidx = sortperm(i)
  permutedims(bs.frame[i[sortidx]...].value, invperm(sortidx))
end

function size{T <: AbstractFloat}(bsdata::BoxStructure{T})
  segsize = bsdata.sizesegment
  numsegments = size(bsdata.frame, 1)
  numdata = segsize * (numsegments-1) + size(bsdata.frame[end].value, 1)
  segsize, numsegments, numdata
end

function testsize{T <: AbstractFloat}(bsdata::BoxStructure{T}...)
  for i = 2:size(bsdata,1)
    size(bsdata[1]) == size(bsdata[i]) || throw(DimensionMismatch("dims of B1 $(size(bsdata[1])) must equal to dims of B$i $(size(bsdata[i]))"))
  end
end

function convert{T<: AbstractFloat,N}(::Type{Array{T}}, bsdata::BoxStructure{T,N})
  s = size(bsdata)
  ret = zeros(T, fill(s[3], N)...)
  @eval begin
    @nloops $N i x->1:$s[2] begin
      readind = @ntuple $N x -> i_{$N-x+1}
      writeind = @ntuple $N x -> seg(i_{$N-x+1}, $s[1], $s[3])
      $ret[writeind...] = readsegments(collect(readind), $bsdata)
    end
  end
  ret
end

@generated function operation{T<: AbstractFloat,N}(op::Function, bsdata::BoxStructure{T,N}...)
    quote
        stumple = size( bsdata, 1)
        sframe = size(bsdata[1].frame)
        (stumple > 1)? testsize(bsdata...): ()
        ret = similar(bsdata[1].frame)
        @nloops $N i x -> (x==$N)? (1:sframe[x]): (i_{x+1}:sframe[x]) begin
            ind = @ntuple $N x -> i_{$N-x+1}
            ret[ind...] = op(map(k ->  bsdata[k].frame[ind...].value, 1:stumple)...)::Array{T, N}
        end
        BoxStructure(ret)
    end
end

@generated function operation{T<: AbstractFloat,N, S <: Real}(op::Function, bsdata::BoxStructure{T,N}, n::S)
    quote
        sframe = size(bsdata.frame)
        ret = similar(bsdata.frame)
        @nloops $N i x -> (x==$N)? (1:sframe[x]): (i_{x+1}:sframe[x]) begin
            ind = @ntuple $N x -> i_{$N-x+1}
            @inbounds ret[ind...] = op(bsdata.frame[ind...].value, n)::Array{T, N}
        end
        BoxStructure(ret)
    end
end

@generated function operation!{T<: AbstractFloat,N, S <: Real}(bsdata::BoxStructure{T,N}, op::Function, n::S)
    quote
        sframe = size(bsdata.frame)
        @nloops $N i x -> (x==$N)? (1:sframe[x]): (i_{x+1}:sframe[x]) begin
            ind = @ntuple $N x -> i_{$N-x+1}
            @inbounds bsdata.frame[ind...] = op(bsdata.frame[ind...].value, n)
        end
    end
end


for op = (:+, :-, :.*, :./)
  @eval ($op){T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, bsdata1::BoxStructure{T, N}) = operation($op, bsdata, bsdata1)
end

for op = (:+, :-, :*, :/)
  @eval ($op){T <: AbstractFloat, S <: Real}(bsdata::BoxStructure{T}, n::S)  = operation($op, bsdata, n)
end

add{T <: AbstractFloat, S <: Real}(bsdata::BoxStructure{T}, n::S)  = operation!(bsdata, +, n)

trace{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}) = mapreduce(i -> trace(bsdata.frame[i,i].value), +, 1:size(bsdata)[2])
vec{T <: AbstractFloat}(bsdata::BoxStructure{T}) = Base.vec(convert(Array{Float64}, bsdata))
vecnorm{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}) = norm(vec(bsdata))

segmentmult{T <: AbstractFloat}(k1::Int, k2::Int, bsdata::BoxStructure{T, 2}) =
mapreduce(i -> readsegments([k1,i], bsdata)*readsegments([i,k2], bsdata), +, 1:size(bsdata.frame, 1))
segmentmult{T <: AbstractFloat}(k1::Int, k2::Int, bsdata::BoxStructure{T, 2}, bsdata1::BoxStructure{T, 2}) =
mapreduce(i -> readsegments([k1,i], bsdata)*readsegments([i,k2], bsdata1), +, 1:size(bsdata.frame, 1))
segmentmult{T <: AbstractFloat}(k1::Int, k2::Int, bsdata::BoxStructure{T, 2}, m::NullableArray{Array{T, 2}}) =
mapreduce(i -> readsegments([k1,i], bsdata)*(m[i,k2].value), +, 1:size(bsdata)[2])
segmentmult{T <: AbstractFloat}(k1::Int, k2::Int, m::NullableArray{Array{T, 2}}, m1::NullableArray{Array{T, 2}}) =
mapreduce(i -> (m[i, k1].value)'*(m1[i,k2].value), +, 1:size(m1, 1))

segmentmult2{T <: AbstractFloat, N}(k::Array{Int, 1}, bsdata::BoxStructure{T, N}, m::NullableArray{Matrix{T}}, mode::Int = 1) =
mapreduce(j -> Tensors.modemult(readsegments([j, k[2:end]...], bsdata), m[k[1], j].value, mode), +, 1:size(bsdata)[2])

function generateperm(i::Int, ar::Array{Int})
    ret = ar
    ret[i], ret[1] = ar[1], ar[i]
    ret
end

segmentmult1{T <: AbstractFloat, N}(k::Array{Int, 1}, bsdata::BoxStructure{T, N}, m::NullableArray{Matrix{T}}, mode::Int = 1) =
mapreduce(j -> Tensors.modemult(readsegments([generateperm(mode, [j, k[2:end]...])...], bsdata), m[k[1], j].value, mode), +, 1:size(bsdata)[2])

segmentmult1{T <: AbstractFloat, N}(k::Array{Int, 1}, m::NullableArray{Array{T, N}}, m1::NullableArray{Matrix{T}}, mode::Int = 1) =
mapreduce(j -> Tensors.modemult(m[generateperm(mode, [j, k[2:end]...])...].value, m1[k[1], j].value, mode), +, 1:size(m1, 1))



function square{T <: AbstractFloat}(bsdata::BoxStructure{T, 2})
    s = size(bsdata)
    ret = NullableArray(Matrix{T}, size(bsdata.frame))
    for i = 1:s[2], j = i:s[2]
        ret[i,j] = segmentmult(i,j, bsdata)
    end
    BoxStructure(ret)
end

function *{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}, bsdata1::BoxStructure{T, 2})
    s = size(bsdata)
    s == size(bsdata1) || throw(DimensionMismatch("dims of B1 $(size(bsdata)) must equal to dims of B2 $(size(bsdata1))"))
    ret = zeros(T, s[3], s[3])
    for i = 1:s[2], j = 1:s[2]
        temp = segmentmult(i,j, bsdata, bsdata1)
        ret[seg(i, s[1], s[3]), seg(j, s[1], s[3])] = temp
    end
    ret
end

function *{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}, mat::Matrix{T})
    s = size(bsdata)
    s[3] == size(mat,1) || throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(mat,1))"))
    ret = similar(mat)
    mat = slise(mat, s[1])
    for i = 1:s[2], j = 1:size(mat,2)
        ret[seg(i, s[1], size(ret,1)), seg(j, s[1], size(ret,2))] = segmentmult(i,j, bsdata, mat)
    end
    ret
end


function slise{T <: AbstractFloat}(mat::Matrix{T}, slisesize::Int)
    segments = ceil(Int, [size(mat)...]/slisesize)
    ret = NullableArray(Array{T, 2}, segments...)
    for k in product(1:segments[1], 1:segments[2])
        ret[k...] = mat[seg(k[1], slisesize, size(mat, 1)),seg(k[2], slisesize, size(mat, 2))]
    end
    ret
end

@generated function modemult{T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, mat::Matrix{T}, mode::Int)
  quote
    s = size(bsdata)
    s[3] == size(mat,2) || throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(mat,1))"))
    mode <= N || throw(DimensionMismatch("mode $mode > tensor dimension $ndims"))
    ret = zeros(T, size(mat,1), fill(s[3], N-1)...)
    m = slise(mat, s[1])
    @nloops $N i x -> (x==$N)? (1:size(m, 1)): (1:s[2]) begin
	ind = @ntuple $N x -> i_{$N-x+1}
        ret[(map(i -> seg(ind[i], s[1], size(ret,i)), 1:N))...] = segmentmult1([ind...], bsdata, m)
    end
    permutedims(ret, generateperm(mode, collect(1:N)))
   end
end

#covariance

function covbs{T <: AbstractFloat}(data::Matrix{T}, segments::Int = 2, corrected::Bool = false)
    len = size(data,2)
    segsizetest(len, segments)
    (len%segments == 0)? () : segments += 1
    ret = NullableArray(Matrix{T}, segments, segments)
    for i = 1:segments, j = i:segments
        ret[i,j] = cov(data[:,seg(i, ceil(Int, len/segments), len)], data[:,seg(j, ceil(Int, len/segments), len)], corrected = corrected)
    end
    BoxStructure(ret)
end

#bcss 2d functions

function bcss{T <: AbstractFloat}(bsdata::BoxStructure{T, 2}, m::Matrix{T})
    s = size(bsdata)
    s[3]  == size(m,1)||throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(m,1))"))
    m = slise(m, s[1])
    ret = NullableArray(Array{T, 2}, size(m,2), size(m,2))
    for i = 1:size(m,2)
      temp = NullableArray(Array{T, 2}, s[2], 1)
      for k = 1:s[2]
          temp[k, 1] = segmentmult(k,i, bsdata, m)
      end
      for j = 1:i
	ret[j,i] = segmentmult(j,1, m, temp)
      end
   end
   BoxStructure(ret)
end

function bcss3{T <: AbstractFloat}(bsdata::BoxStructure{T, 3}, m::Matrix{T})
    s = size(bsdata)
    s[3]  == size(m,2)||throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(m,2))"))
    m = slise(m, s[1])
        ret = NullableArray(Array{T, 3}, fill(size(m,1), 2)...)
    for i = 1:size(m,1)
      temp = NullableArray(Array{T, 3}, s[2], 1, 1)
      for k = 1:s[2]
          temp[k, 1, 1] = segmentmult1([i,k,1], bsdata, m)
      end
      for j = 1:i
	ret[j,i] = segmentmult1([j,1,1], temp, m, 1)
      end
   end
   ret
end


@generated function bcss1{T <: AbstractFloat, N}(bsdata::BoxStructure{T, N}, m::Matrix{T})
    quote
    s = size(bsdata)
    s[3]  == size(m,1)||throw(DimensionMismatch("size of B1 $(s[3]) must equal to size of A $(size(m,1))"))
    m = slise(m, s[1])
    ret = NullableArray(Array{T, N}, fill(size(m,2), N)...)
    @nloops $N i x -> (x==$N)? (1:size(m,2)): (i_{x+1}:size(m,2)) begin
        ind = @ntuple $N x -> i_{$N-x+1}
        temp = NullableArray(Array{T, N}, s[2], 1)
        for k = 1:s[2]
            temp[k, 1] = segmentmult(k,ind[2]..., bsdata, m)
        end
        ret[ind...] = segmentmult(ind[1],1, m, temp)
    end
    BoxStructure(ret)
    end
end



export BoxStructure, convert, +, -, *, /, add, trace, vec, vecnorm, covbs, modemult, square, bcss, bcss1, size, slise, segmentmult1, segmentmult
end

# dokladnosci przy dodawaniu
