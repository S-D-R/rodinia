//========================================================================================================================================================================================================200
//	MAIN HEADER
//========================================================================================================================================================================================================200

//====================================================================================================100
//	DEFINE
//====================================================================================================100

#define fp float

#ifdef RD_WG_SIZE_0_0
#define NUMBER_THREADS RD_WG_SIZE_0_0
#elif defined(RD_WG_SIZE_0)
#define NUMBER_THREADS RD_WG_SIZE_0
#elif defined(RD_WG_SIZE)
#define NUMBER_THREADS RD_WG_SIZE
#else
#define NUMBER_THREADS 256
#endif


//====================================================================================================100
//	End
//====================================================================================================100

//========================================================================================================================================================================================================200
//	End
//========================================================================================================================================================================================================200
