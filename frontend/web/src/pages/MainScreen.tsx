import { useEffect, useState } from 'react';
import { Sidebar } from '../components/Sidebar';
import { userService, type UserProfile, type Family } from '../api/authService';

export const MainScreen = () => {
    const [profile, setProfile] = useState<UserProfile | null>(null);
    const [families, setFamilies] = useState<Family[]>([]);
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const loadInitialData = async () => {
            try {
                const profileRes = await userService.fetchProfile().catch(e => {
                    console.error("Profile fetch failed", e);
                    return null;
                });
                
                const familiesRes = await userService.fetchFamilies().catch(e => {
                    console.error("Families fetch failed", e);
                    return { data: [] };
                });

                if (profileRes) setProfile(profileRes.data);
                if (familiesRes) setFamilies(familiesRes.data);
            } catch (err) {
                setError("Critical loading error");
                console.error(err);
            } finally {
                setIsLoading(false);
            }
        };

        loadInitialData();
    }, []);

    if (isLoading) {
        return (
            <div className="h-screen w-screen flex items-center justify-center bg-gray-900 text-white">
                <div className="animate-spin rounded-full h-12 w-12 border-t-2 border-b-2 border-blue-500 mr-3"></div>
                <span>Loading...</span>
            </div>
        );
    }

    if (error) {
        return <div className="p-10 text-red-500">Error: {error}</div>;
    }

    return (
        <div className="flex h-screen w-screen bg-gray-50 overflow-hidden">
            <Sidebar 
                fName={profile?.first_name || 'User'} 
                lName={profile?.last_name || ''} 
                families={families || []} 
            />
            <main className="flex-1 p-8 overflow-y-auto">
                <header className="mb-8 border-b pb-4">
                </header>
            </main>
        </div>
    );
};