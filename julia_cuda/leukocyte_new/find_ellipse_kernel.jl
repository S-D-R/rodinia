using CUDA

# The number of sample points in each ellipse (stencil)
const NPOINTS = 150
# The maximum radius of a sample ellipse
const MAX_RAD = 20
# The total number of sample ellipses
const NCIRCLES = 7
# The size of the structuring element used in dilation
const STREL_SIZE = 12 * 2 + 1

const c_sin_angle = CuConstantMemory{Float32}(undef, (NPOINTS,))
const c_cos_angle = CuConstantMemory{Float32}(undef, (NPOINTS,))
const c_tX = CuConstantMemory{Int32}(undef, (NCIRCLES, NPOINTS))
const c_tY = CuConstantMemory{Int32}(undef, (NCIRCLES, NPOINTS))
const c_strel = CuConstantMemory{Float32}(undef, (STREL_SIZE, STREL_SIZE))

# NOTE: we emulate unsupported texture and constant accesses with ldg...


# Kernel to find the maximal GICOV value at each pixel of a
#  video frame, based on the input x- and y-gradient matrices
@inbounds function GICOV_kernel(device_grad_x, device_grad_y, device_gicov_out, c_sin_angle, c_cos_angle, c_tX, c_tY)
    # Determine this thread's pixel
    i = blockIdx().x + MAX_RAD + 2
    j = threadIdx().x + MAX_RAD + 2

    # Initialize the maximal GICOV score to 0
    max_GICOV::Float32 = 0

    # Iterate across each stencil
    for k in 1:NCIRCLES
        # Variables used to compute the mean and variance
        #  of the gradients along the current stencil
        sum::Float32 = 0
        M2::Float32 = 0
        mean::Float32 = 0

        # Iterate across each sample point in the current stencil
        for n in 1:NPOINTS
            # Determine the x- and y-coordinates of the current sample
            # point
            y = j + c_tY[k,n]
            x = i + c_tX[k,n]

            # Compute the combined gradient value at the current sample
            # point
            p = ldg(device_grad_x, LinearIndices(device_grad_x)[x,y]) * c_cos_angle[n] +
                ldg(device_grad_y, LinearIndices(device_grad_y)[x,y]) * c_sin_angle[n]

            # Update the running total
            sum += p

            # Partially compute the variance
            delta = p - mean
            mean = mean + (delta / n)
            M2 = M2 + (delta * (p - mean))
        end

        # Compute the mean gradient value across all sample points
        # Finish computing the mean
        mean = sum / NPOINTS

        # Finish computing the variance
        var = M2 / (NPOINTS - 1)

        # Keep track of the maximal GICOV value seen so far
        if (((mean * mean) / var) > max_GICOV)
            max_GICOV = (mean * mean) / var
        end
    end

    # Store the maximal GICOV value
    if (1 <= i <= size(device_gicov_out,1)) &
       (1 <= j <= size(device_gicov_out,2))
      @inbounds device_gicov_out[i,j] = max_GICOV
    else
      @cuprintf("invalid blockid,threadid = %d,%d\n",blockIdx().x,threadIdx().x)
    end
    return
end


# Sets up and invokes the GICOV kernel and returns its output
@inbounds function GICOV_CUDA(host_grad_x, host_grad_y)
    MaxR = MAX_RAD + 2

    # Allocate device memory
    # TODO: should be put in texture memory
    device_grad_x = CuArray(collect(convert(Array{Float32,2},host_grad_x)'))
    device_grad_y = CuArray(collect(convert(Array{Float32,2},host_grad_y)'))

    # Allocate & initialize device memory for result
    # (some elements are not assigned values in the kernel)
    device_gicov_out = CuArray{Float32}(undef,size(device_grad_x,1),size(device_grad_y,2))

    # Setup execution parameters
    num_blocks = size(host_grad_y,2) - (2 * MaxR)
    threads_per_block = size(host_grad_x,1) - (2 * MaxR)

    # @device_code dir = "gicov_asm" 
    @cuda blocks=num_blocks threads=threads_per_block GICOV_kernel(device_grad_x, device_grad_y, device_gicov_out, c_sin_angle, c_cos_angle, c_tX, c_tY)

    Array(device_gicov_out)'
end


# Transfers pre-computed constants used by the two kernels to the GPU
function transfer_constants(host_sin_angle, host_cos_angle, host_tX, host_tY, host_strel)
    copyto!(c_sin_angle, convert(Array{Float32}, host_sin_angle))
    copyto!(c_cos_angle, convert(Array{Float32}, host_cos_angle))
    copyto!(c_tX, host_tX)
    copyto!(c_tY, host_tY)
    copyto!(c_strel, convert(Array{Float32}, host_strel))
end


# Kernel to compute the dilation of the GICOV matrix produced by the GICOV
# kernel
# Each element (i, j) of the output matrix is set equal to the maximal value in
#  the neighborhood surrounding element (i, j) in the input matrix
# Here the neighborhood is defined by the structuring element (c_strel)
function dilate_kernel(img_dev, dilated_out, c_strel)
    # Find the center of the structuring element
    el_center_i = div(size(c_strel)[1],2)
    el_center_j = div(size(c_strel)[2],2)

    img_m = size(img_dev,1)
    img_n = size(img_dev,2)

    # Determine this thread's location in the matrix
    thread_id = ((blockIdx().x -1) * blockDim().x) + threadIdx().x - 1
    i = mod(thread_id, img_m)
    j = div(thread_id, img_m)

    # Initialize the maximum GICOV score seen so far to zero
    max::Float32 = 0.0

    # Iterate across the structuring element
    for el_i in 1:size(c_strel,1), el_j in 1:size(c_strel,2)
        y = i - el_center_i + el_i
        x = j - el_center_j + el_j
        # Make sure we have not gone off the edge of the matrix
        @inbounds if (1 <= y <= size(img_dev,1)) & (1 <= x <= size(img_dev,2)) & (c_strel[el_i,el_j] != 0.0)
            temp = ldg(img_dev, LinearIndices(img_dev)[y,x])
            if temp > max
                max = temp
            end
        end
    end
    # Store the maximum value found
    @inbounds dilated_out[i+1,j+1] = max
    return
end


# Sets up and invokes the dilation kernel and returns its output
function dilate_CUDA(img_in)
    # TODO: should be put in texture memory
    img_dev = CuArray(img_in)
    dilated_out = CuArray{Float32}(undef,(size(img_in,1),size(img_in,2)))

    num_threads = size(img_in,1) * size(img_in,2)
    threads_per_block = 176
    num_blocks = trunc(Int64,num_threads / threads_per_block + 0.5)

    #@device_code dir = "dilate_asm"
    @cuda blocks=num_blocks threads=threads_per_block dilate_kernel(img_dev, dilated_out, c_strel)

    Array(dilated_out)
end
