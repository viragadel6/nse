extern "C" __global__ void copy_values(const float* x, float* y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = x[i];
}
extern "C" __global__ void add_forward(const float* a, const float* b, float* y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = a[i] + b[i];
}
extern "C" __global__ void add_backward(const float* g, float* a, float* b, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) { a[i] += g[i]; b[i] += g[i]; }
}
extern "C" __global__ void gelu_forward(const float* x, float* y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) { float z=x[i]; y[i]=0.5f*z*(1.0f+tanhf(0.7978845608f*(z+0.044715f*z*z*z))); }
}
extern "C" __global__ void gelu_backward(const float* x, const float* g, float* dx, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) { float z=x[i]; float t=tanhf(0.7978845608f*(z+0.044715f*z*z*z)); dx[i]+=g[i]*(0.5f*(1.0f+t)+0.5f*z*(1.0f-t*t)*0.7978845608f*(1.0f+0.134145f*z*z)); }
}
extern "C" __global__ void matmul_forward(const float* a, const float* b, float* y, int m, int n, int k, int tb, float scale) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<m*n) { int r=i/n,c=i%n; float s=0; for(int j=0;j<k;j++) s+=a[r*k+j]*b[tb?c*k+j:j*n+c]; y[i]=s*scale; }
}
extern "C" __global__ void matmul_backward_a(const float* b, const float* gy, float* ga, int m, int n, int k, int tb, float scale) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<m*k) { int r=i/k,c=i%k; float s=0; for(int j=0;j<n;j++) s+=gy[r*n+j]*b[tb?j*k+c:c*n+j]; ga[i]+=s*scale; }
}
extern "C" __global__ void matmul_backward_b(const float* a, const float* gy, float* gb, int m, int n, int k, int tb, float scale) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<n*k) { int r=tb?i%k:i/n,c=tb?i/k:i%n; float s=0; for(int j=0;j<m;j++) s+=a[j*k+r]*gy[j*n+c]; gb[i]+=s*scale; }
}
extern "C" __global__ void norm_forward(const float* x, float* y, int rows, int cols, int l2) {
    int r=blockIdx.x*blockDim.x+threadIdx.x;
    if(r<rows) { float mean=0,variance=0; if(!l2) { for(int c=0;c<cols;c++) mean+=x[r*cols+c]; mean/=cols; }
        for(int c=0;c<cols;c++){float z=x[r*cols+c]-mean;variance+=z*z;}
        float inv=rsqrtf(l2?fmaxf(variance,1e-20f):variance/cols+1e-5f);
        for(int c=0;c<cols;c++)y[r*cols+c]=(x[r*cols+c]-mean)*inv;
    }
}
extern "C" __global__ void norm_backward(const float* x, const float* y, const float* gy, float* gx, int rows, int cols, int l2) {
    int r=blockIdx.x*blockDim.x+threadIdx.x;
    if(r<rows) { float mean=0,variance=0,sum=0,dot=0; if(!l2){for(int c=0;c<cols;c++)mean+=x[r*cols+c];mean/=cols;}
        for(int c=0;c<cols;c++){float z=x[r*cols+c]-mean;variance+=z*z;sum+=gy[r*cols+c];dot+=gy[r*cols+c]*y[r*cols+c];}
        float inv=rsqrtf(l2?fmaxf(variance,1e-20f):variance/cols+1e-5f);
        for(int c=0;c<cols;c++)gx[r*cols+c]+=inv*(gy[r*cols+c]-(l2?0.0f:sum/cols)-y[r*cols+c]*dot/(l2?1.0f:(float)cols));
    }
}
extern "C" __global__ void softmax_forward(const float* x, float* y, int rows, int cols) {
    int r=blockIdx.x*blockDim.x+threadIdx.x;
    if(r<rows){float mx=-__int_as_float(0x7f800000),sum=0;for(int c=0;c<cols;c++)mx=fmaxf(mx,x[r*cols+c]);for(int c=0;c<cols;c++){float z=expf(x[r*cols+c]-mx);y[r*cols+c]=z;sum+=z;}for(int c=0;c<cols;c++)y[r*cols+c]/=sum;}
}
extern "C" __global__ void softmax_backward(const float* y, const float* gy, float* gx, int rows, int cols) {
    int r=blockIdx.x*blockDim.x+threadIdx.x;
    if(r<rows){float dot=0;for(int c=0;c<cols;c++)dot+=y[r*cols+c]*gy[r*cols+c];for(int c=0;c<cols;c++)gx[r*cols+c]+=y[r*cols+c]*(gy[r*cols+c]-dot);}
}
extern "C" __global__ void pool_forward(const float* x, float* y, int rows, int cols) {
    int c=blockIdx.x*blockDim.x+threadIdx.x;
    if(c<cols){float s=0;for(int r=0;r<rows;r++)s+=x[r*cols+c];y[c]=s/rows;}
}
extern "C" __global__ void pool_backward(const float* gy, float* gx, int rows, int cols) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<rows*cols)gx[i]+=gy[i%cols]/rows;
}
extern "C" __global__ void lookup_forward(const float* words, const float* positions, const float* structure, const unsigned int* tokens, const float* features, float* y, int rows, int cols) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<rows*cols){int r=i/cols,c=i%cols;float z=words[tokens[r]*cols+c]+positions[i];for(int f=0;f<6;f++)z+=features[r*6+f]*structure[f*cols+c];y[i]=z;}
}
extern "C" __global__ void lookup_backward(const float* gy, const unsigned int* tokens, const float* features, float* words, float* positions, float* structure, int rows, int cols) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<rows*cols){int r=i/cols,c=i%cols;float z=gy[i];atomicAdd(words+tokens[r]*cols+c,z);positions[i]+=z;for(int f=0;f<6;f++)atomicAdd(structure+f*cols+c,z*features[r*6+f]);}
}
extern "C" __global__ void contrastive_norms(const float* queries, const float* documents, float* norms, int batch, int dims) {
    int r=blockIdx.x*blockDim.x+threadIdx.x;
    if(r<batch){float q=0,d=0;for(int i=0;i<dims;i++){q+=queries[r*4096+i]*queries[r*4096+i];d+=documents[r*4096+i]*documents[r*4096+i];}norms[r]=rsqrtf(fmaxf(q,1e-20f));norms[batch+r]=rsqrtf(fmaxf(d,1e-20f));}
}
extern "C" __global__ void contrastive_forward(const float* queries, const float* documents, const float* temperature, const float* norms, float* similarities, float* probabilities, float* losses, int batch, int dims, float weight) {
    int r=blockIdx.x*blockDim.x+threadIdx.x;
    if(r<batch){float temp=expf(fminf(fmaxf(temperature[0],-4.605170186f),-1.609437912f)),mx=-__int_as_float(0x7f800000),sum=0;
        for(int c=0;c<batch;c++){float s=0;for(int d=0;d<dims;d++)s+=queries[r*4096+d]*documents[c*4096+d];s*=norms[r]*norms[batch+c];similarities[r*batch+c]=s;float z=s/temp;probabilities[r*batch+c]=z;mx=fmaxf(mx,z);}
        float positive=probabilities[r*batch+r];for(int c=0;c<batch;c++){float z=expf(probabilities[r*batch+c]-mx);probabilities[r*batch+c]=z;sum+=z;}
        losses[r]=weight*(logf(sum)+mx-positive)/batch;for(int c=0;c<batch;c++)probabilities[r*batch+c]/=sum;
    }
}
extern "C" __global__ void contrastive_backward(const float* queries, const float* documents, const float* temperature, const float* norms, const float* similarities, const float* probabilities, float* gqueries, float* gdocuments, float* gtemperature, int batch, int dims, float weight) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<batch*4096){int r=i/4096,d=i%4096;if(d>=dims)return;float temp=expf(fminf(fmaxf(temperature[0],-4.605170186f),-1.609437912f));float gq=0,gd=0,tg=0;
        float qn=norms[r],dn=norms[batch+r];
        for(int c=0;c<batch;c++){float qs=similarities[r*batch+c],ds=similarities[c*batch+r];float qcoeff=(probabilities[r*batch+c]-(r==c?1.0f:0.0f))*weight/(batch*temp);float dcoeff=(probabilities[c*batch+r]-(r==c?1.0f:0.0f))*weight/(batch*temp);gq+=qcoeff*qn*(documents[c*4096+d]*norms[batch+c]-queries[i]*qn*qs);gd+=dcoeff*dn*(queries[c*4096+d]*norms[c]-documents[i]*dn*ds);tg-=qcoeff*qs;}
        gqueries[i]+=gq;gdocuments[i]+=gd;if(d==0)atomicAdd(gtemperature,tg);
    }
}
extern "C" __global__ void gradient_norm(const float* gradient, float* result, int n) {
    if(blockIdx.x==0&&threadIdx.x==0){double sum=0;for(int i=0;i<n;i++){double g=gradient[i];sum+=g*g;}result[0]=(float)sqrt(sum);}
}
extern "C" __global__ void adam_update(float* parameters, const float* gradient, float* first, float* second, const float* norm, int n, float lr, float decay, float clip, float correction1, float correction2) {
    int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<n){float g=gradient[i]*fminf(1.0f,clip/fmaxf(norm[0],1e-20f));float m=0.9f*first[i]+0.1f*g,v=0.999f*second[i]+0.001f*g*g;first[i]=m;second[i]=v;float wd=i==n-1?0.0f:decay;float p=parameters[i]-lr*((m/correction1)/(sqrtf(v/correction2)+1e-8f)+wd*parameters[i]);parameters[i]=i==n-1?fminf(fmaxf(p,-4.605170186f),-1.609437912f):p;}
}
