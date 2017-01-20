


#include "cuda_computing.cuh"

#define NUM_THREADS_PER_BLOCK 128

namespace Device {
	// CUDA global constants
	__device__ __constant__
		float EPSILON2;
	__device__ __constant__
		float DTGRAVITY;
	__device__ __constant__
		int NBODIES;
	__device__ __constant__
		int NTHREADS;

	// array of masses
	float *masses;
	// array of velocities
	float3 *velocities;
	// array of positions
	float3 *positions;

	////////////////////////////////////////////////////////////////////////////////////////////////////
	// physics calculations between bodies
	// NOTES: try not using EPSILON for calculations
	// NOTES: more than one particle in one thread
	////////////////////////////////////////////////////////////////////////////////////////////////////
	__device__
		float3
		bodyBodyInteraction(float3 myPos, float3 othPos, float mass_oth, float3 velo) {
		float3 dir;
		//3 FLOP
		dir.x = othPos.x - myPos.x;
		dir.y = othPos.y - myPos.y;
		dir.z = othPos.z - myPos.z;
		// 6 FLOP
		float distSqr = dir.x*dir.x + dir.y*dir.y + dir.z*dir.z + EPSILON2;
		// 4 FLOP
		float partForce = mass_oth / sqrtf(distSqr*distSqr*distSqr);
		// 6 FLOP
		velo.x += dir.x * partForce;
		velo.y += dir.y * partForce;
		velo.z += dir.z * partForce;
		// in total 19 FLOP per body body Interaction
		return velo;
	}

	////////////////////////////////////////////////////////////////////////////////////////////////////
	// kernel computing velocities
	////////////////////////////////////////////////////////////////////////////////////////////////////
	__global__
		void
		computeVelocities(float3 *positions, float* masses, float3 *velocities) {
		unsigned int tidx = blockIdx.x * blockDim.x + threadIdx.x;
		if (tidx < NBODIES) {
			float3 myPos = positions[tidx];
			float3 myVelo = velocities[tidx];
			for (unsigned int k = 0; k < NBODIES; ++k)
			{
				myVelo = bodyBodyInteraction(myPos, positions[k], masses[k], myVelo);
			}
			
			myPos.x += myVelo.x * DTGRAVITY;
			myPos.y += myVelo.y * DTGRAVITY;
			myPos.z += myVelo.z * DTGRAVITY;

			positions[tidx] = myPos;
			velocities[tidx] = myVelo;
		}
	}


	////////////////////////////////////////////////////////////////////////////////////////////////////
	// kernel using shared Memory + doing 2 body calculations at once
	////////////////////////////////////////////////////////////////////////////////////////////////////
	__global__
		void
		twoComputeVelocities(float3 *positions, float* masses, float3 *velocities) {
		unsigned int tidA = blockIdx.x * blockDim.x*2 + threadIdx.x*2;
		unsigned int tidB = tidA + 1;

		if (tidA < NBODIES) {
			if (tidB < NBODIES) {
				float3 myPosA = positions[tidA];
				float3 myPosB = positions[tidB];
				float3 myVeloA = velocities[tidA];
				float3 myVeloB = velocities[tidB];
				for (unsigned int k = 0; k < NBODIES; ++k)
				{
					float3 curPos = positions[k];
					float curMass = masses[k];
					myVeloA = bodyBodyInteraction(myPosA, curPos, curMass, myVeloA);
					myVeloB = bodyBodyInteraction(myPosB, curPos, curMass, myVeloB);
				}
				myPosA.x += myVeloA.x * DTGRAVITY;
				myPosA.y += myVeloA.y * DTGRAVITY;
				myPosA.z += myVeloA.z * DTGRAVITY;
				myPosB.x += myVeloB.x * DTGRAVITY;
				myPosB.y += myVeloB.y * DTGRAVITY;
				myPosB.z += myVeloB.z * DTGRAVITY;

				positions[tidA] = myPosA;
				positions[tidB] = myPosB;
				velocities[tidA] = myVeloA;
				velocities[tidB] = myVeloB;
			}
			else {
				float3 myPos = positions[tidA];
				float3 myVelo = velocities[tidA];
				for (unsigned int k = 0; k < NBODIES; ++k)
				{
					myVelo = bodyBodyInteraction(myPos, positions[k], masses[k], myVelo);
				}
				myPos.x += myVelo.x * DTGRAVITY;
				myPos.y += myVelo.y * DTGRAVITY;
				myPos.z += myVelo.z * DTGRAVITY;

				positions[tidA] = myPos;
				velocities[tidA] = myVelo;
			}
		}
	}

	////////////////////////////////////////////////////////////////////////////////////////////////////
	// physics calculations between bodies [SHARED MEMORY]
	////////////////////////////////////////////////////////////////////////////////////////////////////
	__device__
		float3
		smBodyBodyInteraction(float3 myPos, float4 othPos, float3 velo) {
		float3 dir;
		//3 FLOP
		dir.x = othPos.x - myPos.x;
		dir.y = othPos.y - myPos.y;
		dir.z = othPos.z - myPos.z;
		// 6 FLOP
		float distSqr = dir.x*dir.x + dir.y*dir.y + dir.z*dir.z + EPSILON2;
		// 4 FLOP
		float partForce = rsqrtf(distSqr*distSqr*distSqr);
		partForce *= othPos.w;
		// 6 FLOP
		velo.x += dir.x * partForce;
		velo.y += dir.y * partForce;
		velo.z += dir.z * partForce;
		return velo;
	}

	////////////////////////////////////////////////////////////////////////////////////////////////////
	// kernel using shared Memory computing velocities
	// NVS4200M has 48KB of SM per SMP meaning 1 block on one SMP uses that much, 2 blocks split the 48KB...
	////////////////////////////////////////////////////////////////////////////////////////////////////
	__global__
		void
		smComputeVelocities(float3 *positions, float* masses, float3 *velocities) {
		unsigned int tidx = blockIdx.x * blockDim.x + threadIdx.x;
		extern __shared__ float4 smPos[];

		if (tidx < NBODIES) {
			float3 myPos = positions[tidx];
			float3 myVelo = velocities[tidx];
			// we do this NBODIES/NTHREADS times, the number of total blocks in our kernel
			for (int i = 0, b_tile = 0; i < NBODIES; i += NUM_THREADS_PER_BLOCK, b_tile++) {
				int idx = b_tile * blockDim.x + threadIdx.x;
				smPos[threadIdx.x].x = positions[idx].x;
				smPos[threadIdx.x].y = positions[idx].y;
				smPos[threadIdx.x].z = positions[idx].z;
				smPos[threadIdx.x].w = masses[idx];
				__syncthreads();
				//compute interactions in our current sharedMemory

				for (unsigned int i = 0; i < NUM_THREADS_PER_BLOCK; i++)
				{
					myVelo = smBodyBodyInteraction(myPos, smPos[i], myVelo);
				}
				__syncthreads();
			}

			myPos.x += myVelo.x * DTGRAVITY;
			myPos.y += myVelo.y * DTGRAVITY;
			myPos.z += myVelo.z * DTGRAVITY;

			__syncthreads();
			positions[tidx] = myPos;
			velocities[tidx] = myVelo;
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// constructor, copies all the bodies into this class
////////////////////////////////////////////////////////////////////////////////////////////////////
Cuda_Computing::Cuda_Computing(std::vector<Body> &bodies) : N(bodies.size()) {
	this->positions = new float3[N];
	this->masses = new float[N];
	this->velocities = new float3[N];

	for (unsigned int i = 0; i < N; ++i)
	{
		positions[i].x = bodies[i].position.x;
		positions[i].y = bodies[i].position.y;
		positions[i].z = bodies[i].position.z;

		masses[i] = bodies[i].mass;

		velocities[i].x = bodies[i].velocity.x;
		velocities[i].y = bodies[i].velocity.y;
		velocities[i].z = bodies[i].velocity.z;
	}

	std::cerr << "Cuda_Computing::Cuda_Computing() - Copying of " << N << " bodies done." << std::endl;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
// initializes device, detects hardware, number of threads per block
////////////////////////////////////////////////////////////////////////////////////////////////////
bool
Cuda_Computing::initDevice() {
	//check execution environment
	int deviceCount = 0;
	int device_handle = 0;
	errorCheckCuda(cudaGetDeviceCount(&deviceCount));

	if (0 == deviceCount) {
		std::cerr << "initDevice() : No CUDA device found." << std::endl;
		return false;
	}

	if (deviceCount > 1) {
		std::cerr << "initDevice() : Multiple CUDA devices found. Using first one." << std::endl;
	}

	// set the device
	errorCheckCuda(cudaSetDevice(device_handle));

	cudaDeviceProp device_props;
	errorCheckCuda(cudaGetDeviceProperties(&device_props, device_handle));
	//std::cerr << "Max CC: " << device_props.major << "   Min CC: " << device_props.minor << std::endl;

	// determine thread layout
	// num of threads on 1 block, thread layout per block
	blockSize = dim3(NUM_THREADS_PER_BLOCK, 1, 1);
	int numBlocks = N / NUM_THREADS_PER_BLOCK;
	if (0 != N % blockSize.x) numBlocks++;
	// number of blocks, block layout on grid
	gridSize = dim3(numBlocks, 1, 1);

	//determine thread layout when doing 2 body calculations per thread
	int numBlocksHalf = N / (NUM_THREADS_PER_BLOCK*2);
	if (0 != N % (blockSize.x*2)) numBlocksHalf++;
	// number of blocks, block layout on grid
	gridSizeHalf = dim3(numBlocksHalf, 1, 1);


	std::cerr << "num blocks = " << numBlocks << " :: " 
		<< "threads per Block = " << NUM_THREADS_PER_BLOCK << " :: " 
		<< "num blocks half = " << numBlocksHalf << std::endl;

	float dtG = G*DT;
	int nTh = NUM_THREADS_PER_BLOCK;

	errorCheckCuda(cudaMemcpyToSymbol(Device::EPSILON2, &EPS2, sizeof(float), 0, cudaMemcpyHostToDevice));
	errorCheckCuda(cudaMemcpyToSymbol(Device::DTGRAVITY, &dtG, sizeof(float), 0, cudaMemcpyHostToDevice));
	errorCheckCuda(cudaMemcpyToSymbol(Device::NBODIES, &N, sizeof(int), 0, cudaMemcpyHostToDevice));
	errorCheckCuda(cudaMemcpyToSymbol(Device::NTHREADS, &blockSize.x, sizeof(int), 0, cudaMemcpyHostToDevice));
	return true;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
// creating vertexBuffer for openGL/cuda inop
////////////////////////////////////////////////////////////////////////////////////////////////////
bool
Cuda_Computing::initVertexBuffer() {
	// allocate & register the vertexbuffer
	cudaGraphicsResource *cuda_vbo_resources[3];
	GLuint vao;
	GLuint vbo_pos;
	GLuint vbo_mass;
	GLuint vbo_velos;

	// create a vertex array of our device pointer for opengl/cuda inop
	glGenVertexArrays(3, &vao);
	glBindVertexArray(vao);

	glGenBuffers(1, &vbo_pos);
	glBindBuffer(GL_ARRAY_BUFFER, vbo_pos);
	glBufferData(GL_ARRAY_BUFFER, N * sizeof(float3), positions, GL_DYNAMIC_COPY); 	// buffer data with our positions
	glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, NULL);
	glEnableVertexAttribArray(0);

	glGenBuffers(1, &vbo_mass);
	glBindBuffer(GL_ARRAY_BUFFER, vbo_mass);
	glBufferData(GL_ARRAY_BUFFER, N * sizeof(float), masses, GL_DYNAMIC_COPY);
	glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, NULL);
	glEnableVertexAttribArray(1);

	glGenBuffers(1, &vbo_velos);
	glBindBuffer(GL_ARRAY_BUFFER, vbo_velos);
	glBufferData(GL_ARRAY_BUFFER, N * sizeof(float3), velocities, GL_DYNAMIC_COPY);
	glVertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, 0, NULL);
	glEnableVertexAttribArray(2);

	glBindVertexArray(vao);

	//cudaGLRegisterBufferObject(vbo); ///deprecated
	errorCheckCuda(cudaGraphicsGLRegisterBuffer(&cuda_vbo_resources[0], vbo_pos, cudaGraphicsMapFlagsNone));
	errorCheckCuda(cudaGraphicsGLRegisterBuffer(&cuda_vbo_resources[1], vbo_mass, cudaGraphicsMapFlagsNone));
	errorCheckCuda(cudaGraphicsGLRegisterBuffer(&cuda_vbo_resources[2], vbo_velos, cudaGraphicsMapFlagsNone));

	// Map the buffer to CUDA
	//cudaGLMapBufferObject(&vptr, vbo); ///deprecated
	errorCheckCuda(cudaGraphicsMapResources(3, cuda_vbo_resources));
	size_t numBytes;
	errorCheckCuda(cudaGraphicsResourceGetMappedPointer((void**)&Device::positions, &numBytes, cuda_vbo_resources[0]));
	errorCheckCuda(cudaGraphicsResourceGetMappedPointer((void**)&Device::masses, &numBytes, cuda_vbo_resources[1]));
	errorCheckCuda(cudaGraphicsResourceGetMappedPointer((void**)&Device::velocities, &numBytes, cuda_vbo_resources[2]));

	// Unmap the buffer
	//cudaGLUnmapBufferObject(vbo); /// deprecated
	errorCheckCuda(cudaGraphicsUnmapResources(3, cuda_vbo_resources));
	return true;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
// kernel entry point
////////////////////////////////////////////////////////////////////////////////////////////////////
float
Cuda_Computing::computeNewPositions() {
	float time;
	cudaEvent_t start, stop;
	errorCheckCuda(cudaEventCreate(&start));
	errorCheckCuda(cudaEventCreate(&stop));
	errorCheckCuda(cudaEventRecord(start, 0));

	//Device::twoComputeVelocities << < gridSizeHalf, blockSize, sizeof(float4)*NUM_THREADS_PER_BLOCK
	//	>> > (Device::positions, Device::masses, Device::velocities);

	Device::computeVelocities << < gridSize, blockSize, sizeof(float4)*NUM_THREADS_PER_BLOCK
		>> > (Device::positions, Device::masses, Device::velocities);

	//errorCheckCuda(cudaPeekAtLastError());
	errorCheckCuda(cudaDeviceSynchronize());
	errorCheckCuda(cudaEventRecord(stop, 0));
	errorCheckCuda(cudaEventSynchronize(stop));
	errorCheckCuda(cudaEventElapsedTime(&time, start, stop));

	return time;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
// returns the number of bodies 
////////////////////////////////////////////////////////////////////////////////////////////////////
size_t
Cuda_Computing::getSize() const {
	return N;
}
